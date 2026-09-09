#pragma once
#include "asio.hpp"
#include "pq_api.hpp"
#include "pq_data.hpp"
#include <functional>
#include <list>
#include <map>
#include <memory>
#include <optional>
#include <unordered_map>
#include <vector>

namespace moon::pq {
struct result_deleter {
    void operator()(PGresult* p) const {
        if (p)
            library().PQclear(p);
    }
};
using result_ptr = std::unique_ptr<PGresult, result_deleter>;

// All methods and callbacks run on one Moon worker's io_context. No callback
// enters Lua or retains a lua_State*. One connection accepts one operation.
class connection: public std::enable_shared_from_this<connection> {
public:
    using notify_fn = std::function<void(int64_t)>;
    connection(asio::io_context& io, notify_fn notify, size_t cache_capacity = 100):
        io_(io),
        resolver_(io),
        readiness_(io),
        timer_(io),
        notify_(std::move(notify)),
        cache_capacity_(cache_capacity) {}
    ~connection() {
        detach();
        if (conn_)
            library().PQfinish(conn_);
    }
    bool busy() const {
        return busy_;
    }
    bool ready() const {
        return ready_;
    }
    bool connected() const {
        return conn_ && library().PQstatus(conn_) == CONNECTION_OK;
    }
    int transaction_status() const {
        return conn_ ? library().PQtransactionStatus(conn_) : PQTRANS_UNKNOWN;
    }
    const std::optional<error>& failure() const {
        return failure_;
    }
    const std::vector<result_set>& results() const {
        return results_;
    }
    size_t cached_statements() const {
        return cache_.size();
    }
    bool transaction_committed() const {
        return committed_;
    }
    size_t result_bytes() const {
        return bytes_;
    }
    void consumed() {
        results_.clear();
        failure_.reset();
        ready_ = false;
    }

    void close(bool notify = true) {
        if (!notify) {
            notify_ = {};
            retire();
            timer_.cancel();
            busy_ = false;
            connecting_ = false;
            ++epoch_;
            consumed();
            return;
        }
        if (busy_) {
            failure_ = error { "CLOSED", "connection closed during operation" };
            retire();
            complete(notify);
        } else {
            retire();
        }
    }

    void connect(std::map<std::string, std::string> options, int64_t session, uint32_t timeout) {
        if (conn_)
            throw std::runtime_error("connection already opened");
        begin(session, timeout, true);
        guard([&] {
            options_ = std::move(options);
            addresses_.clear();
            address_index_ = 0;
            // No libpq DNS lookup is allowed on the Moon worker. Resolve TCP names
            // through Asio first, keep host for certificate/password-file matching.
            const auto host = options_.count("host") ? options_.at("host") : "127.0.0.1";
            const auto port = options_.count("port") ? options_.at("port") : "5432";
            if (host.empty() || host.find(',') != std::string::npos || host[0] == '/'
                || host[0] == '@')
            {
                fail(
                    "INVALID",
                    "this binding accepts one TCP host (not Unix sockets or multi-host URLs)"
                );
                return;
            }
            options_["host"] = host;
            if (options_.count("hostaddr") && !options_["hostaddr"].empty()) {
                asio::error_code ec;
                asio::ip::make_address(options_["hostaddr"], ec);
                if (ec) {
                    fail("INVALID", "hostaddr must be a numeric IP address");
                    return;
                }
                addresses_.push_back(options_["hostaddr"]);
                start_connect();
                return;
            }
            auto self = shared_from_this();
            auto epoch = epoch_;
            resolver_.async_resolve(
                host,
                port,
                [self, epoch](
                    const asio::error_code& ec,
                    asio::ip::tcp::resolver::results_type addresses
                ) {
                    if (!self->active(epoch))
                        return;
                    self->guard([&] {
                        if (ec) {
                            self->fail("SOCKET", "DNS resolution failed: " + ec.message());
                            return;
                        }
                        for (const auto& entry: addresses) {
                            self->addresses_.push_back(entry.endpoint().address().to_string());
                        }
                        if (self->addresses_.empty()) {
                            self->fail("SOCKET", "DNS returned no addresses");
                            return;
                        }
                        self->options_["hostaddr"] = self->addresses_.front();
                        self->start_connect();
                    });
                }
            );
        });
    }

    enum class command { query, batch, prepare, prepared };
    void submit(
        command cmd,
        std::string sql,
        std::vector<parameter> params,
        std::string name,
        int64_t session,
        uint32_t timeout,
        size_t max_rows,
        size_t max_bytes
    ) {
        if (!connected())
            throw std::runtime_error("connection is closed");
        if ((cmd == command::prepare || cmd == command::prepared)
            && (name.empty() || name.compare(0, 10, "__moon_pq_") == 0))
            throw std::runtime_error(
                "prepared name must be nonempty and must not use __moon_pq_ prefix"
            );
        begin(session, timeout, false);
        guard([&] {
            max_rows_ = max_rows;
            max_bytes_ = max_bytes;
            command_ = cmd;
            current_ = { std::move(sql), std::move(params) };
            explicit_name_ = std::move(name);
            start_statement();
        });
    }

    // One deadline, one completion notification, and exclusive ownership of BEGIN/COMMIT.
    // Validate the entire input before submitting any SQL. Never replay a failed statement.
    void transaction(
        std::vector<statement> statements,
        int64_t session,
        uint32_t timeout,
        size_t max_rows,
        size_t max_bytes
    ) {
        if (!connected())
            throw std::runtime_error("connection is closed");
        for (const auto& s: statements)
            validate_transaction_sql(s.sql);
        begin(session, timeout, false);
        guard([&] {
            transaction_ = true;
            statements_ = std::move(statements);
            max_rows_ = max_rows;
            max_bytes_ = max_bytes;
            command_ = command::query;
            phase_ = phase::tx_begin;
            send_control("BEGIN");
        });
    }

private:
    enum class phase {
        execute,
        cached_execute,
        cache_prepare,
        cache_evict,
        tx_begin,
        tx_commit,
        tx_rollback
    };
    struct cache_entry {
        std::string key, name;
    };

    void start_statement() {
        if (command_ != command::query || !cache_capacity_ || !cacheable_sql(current_.sql)) {
            phase_ = phase::execute;
            send_query(command_, explicit_name_);
            return;
        }
        const auto key = statement_key(current_);
        auto found = cache_.find(key);
        if (found != cache_.end()) {
            lru_.splice(lru_.begin(), lru_, found->second);
            phase_ = phase::cached_execute;
            send_query(command::prepared, found->second->name);
            return;
        }
        pending_cache_ = { key, "__moon_pq_" + std::to_string(++statement_sequence_) };
        if (cache_.size() >= cache_capacity_) {
            auto victim = std::move(lru_.back());
            cache_.erase(victim.key);
            lru_.pop_back();
            phase_ = phase::cache_evict;
            send_control("DEALLOCATE \"" + victim.name + "\"");
        } else {
            phase_ = phase::cache_prepare;
            send_query(command::prepare, pending_cache_.name);
        }
    }
    void send_control(const std::string& sql) {
        send_started(library().PQsendQuery(conn_, sql.c_str()), false);
    }
    void send_query(command cmd, const std::string& name) {
        const auto& params = current_.params;
        std::vector<Oid> types;
        std::vector<const char*> values;
        std::vector<int> lengths, formats;
        types.reserve(params.size());
        values.reserve(params.size());
        lengths.reserve(params.size());
        formats.reserve(params.size());
        for (const auto& p: params) {
            types.push_back(p.oid);
            values.push_back(p.value ? p.value->data() : nullptr);
            lengths.push_back(p.value ? static_cast<int>(p.value->size()) : 0);
            formats.push_back(p.format);
        }
        auto& pq = library();
        int sent = 0;
        switch (cmd) {
            case command::query:
                sent = pq.PQsendQueryParams(
                    conn_,
                    current_.sql.c_str(),
                    static_cast<int>(params.size()),
                    types.data(),
                    values.data(),
                    lengths.data(),
                    formats.data(),
                    0
                );
                break;
            case command::batch:
                sent = pq.PQsendQuery(conn_, current_.sql.c_str());
                break;
            case command::prepare:
                sent = pq.PQsendPrepare(
                    conn_,
                    name.c_str(),
                    current_.sql.c_str(),
                    static_cast<int>(types.size()),
                    types.data()
                );
                break;
            case command::prepared:
                sent = pq.PQsendQueryPrepared(
                    conn_,
                    name.c_str(),
                    static_cast<int>(params.size()),
                    values.data(),
                    lengths.data(),
                    formats.data(),
                    0
                );
                break;
        }
        send_started(sent, cmd != command::prepare);
    }
    void send_started(int sent, bool single_row) {
        if (!sent) {
            fail("SOCKET", library().PQerrorMessage(conn_));
            return;
        }
        if (single_row && !library().PQsetSingleRowMode(conn_)) {
            fail("PROTOCOL", "cannot enable single-row result mode");
            return;
        }
        exchange();
    }
    void next_transaction_statement() {
        if (statement_index_ == statements_.size()) {
            phase_ = phase::tx_commit;
            send_control("COMMIT");
        } else {
            current_ = std::move(statements_[statement_index_]);
            start_statement();
        }
    }
    // Called only after ReadyForQuery has been drained. Internal phases do not notify Lua.
    void wire_complete() {
        if (phase_ == phase::tx_rollback) {
            if (transaction_status() != PQTRANS_IDLE)
                retire();
            complete();
            return;
        }
        if (failure_) {
            // A user DEALLOCATE/DISCARD or schema change can invalidate a cached plan.
            // Drop that connection without retrying SQL; the next request starts fresh.
            const bool stale = phase_ == phase::cache_evict
                || (phase_ == phase::cached_execute
                    && (failure_->sqlstate == "26000" || failure_->sqlstate == "0A000"));
            if (stale || phase_ == phase::tx_begin || phase_ == phase::tx_commit) {
                retire();
                complete();
                return;
            }
            if (transaction_) {
                phase_ = phase::tx_rollback;
                send_control("ROLLBACK");
            } else {
                if (command_ == command::batch || transaction_status() != PQTRANS_IDLE)
                    retire();
                complete();
            }
            return;
        }
        switch (phase_) {
            case phase::cache_evict:
                phase_ = phase::cache_prepare;
                send_query(command::prepare, pending_cache_.name);
                return;
            case phase::cache_prepare:
                lru_.push_front(std::move(pending_cache_));
                cache_.emplace(lru_.front().key, lru_.begin());
                phase_ = phase::cached_execute;
                send_query(command::prepared, lru_.front().name);
                return;
            case phase::tx_begin:
                if (transaction_status() != PQTRANS_INTRANS) {
                    fail("TRANSACTION", "BEGIN did not open a transaction");
                    return;
                }
                next_transaction_statement();
                return;
            case phase::tx_commit:
                if (transaction_status() != PQTRANS_IDLE) {
                    fail("TRANSACTION", "COMMIT did not return idle");
                    return;
                }
                committed_ = true;
                complete();
                return;
            default:
                if (transaction_) {
                    if (transaction_status() != PQTRANS_INTRANS) {
                        fail("TRANSACTION", "transaction unexpectedly ended");
                        return;
                    }
                    ++statement_index_;
                    next_transaction_statement();
                } else {
                    if (transaction_status() != PQTRANS_IDLE) {
                        fail("TRANSACTION", "manual BEGIN is not supported; use transaction()");
                        return;
                    }
                    complete();
                }
        }
    }
    bool active(uint64_t epoch) const {
        return busy_ && epoch == epoch_;
    }
    template<typename F>
    void guard(F&& f) {
        try {
            f();
        } catch (const std::exception& e) {
            fail("ERROR", e.what());
        }
    }
    void begin(int64_t session, uint32_t timeout, bool connecting) {
        if (busy_ || ready_)
            throw std::runtime_error("connection is busy or has an unconsumed result");
        connecting_ = connecting;
        session_ = session;
        ++epoch_;
        rows_ = bytes_ = 0;
        failure_.reset();
        results_.clear();
        transaction_ = false;
        committed_ = false;
        statement_index_ = 0;
        statements_.clear();
        current_ = {};
        explicit_name_.clear();
        pending_cache_ = {};
        in_rows_ = false;
        phase_ = phase::execute;
        timer_.expires_after(std::chrono::milliseconds(timeout));
        auto self = shared_from_this();
        auto epoch = epoch_;
        timer_.async_wait([self, epoch](const asio::error_code& ec) {
            if (!ec && self->active(epoch))
                self->fail("TIMEOUT", "libpq operation timed out; SQL is not replayed");
        });
        busy_ = true;
    }
    void detach() {
        ++wait_id_;
#ifdef _WIN32
        // Never attach libpq's SOCKET to IOCP: releasing that borrowed socket
        // is not supported by all Winsock providers. Only own a waitable event.
        if (watched_socket_ != INVALID_SOCKET) {
            WSAEventSelect(watched_socket_, nullptr, 0);
            watched_socket_ = INVALID_SOCKET;
        }
        if (readiness_.is_open()) {
            asio::error_code ec;
            readiness_.cancel(ec);
            ResetEvent(readiness_.native_handle());
        }
#else
        if (readiness_.is_open()) {
            asio::error_code ec;
            readiness_.cancel(ec);
            // libpq owns the descriptor. Never close it through Asio.
            readiness_.release(ec);
        }
#endif
    }
    void retire() {
        detach();
        resolver_.cancel();
        if (conn_) {
            library().PQfinish(conn_);
            conn_ = nullptr;
        }
        options_.clear();
        cache_.clear();
        lru_.clear();
    }
    void complete(bool notify = true) {
        if (!busy_)
            return;
        detach();
        timer_.cancel();
        resolver_.cancel();
        busy_ = false;
        ready_ = true;
        connecting_ = false;
        statements_.clear();
        current_ = {};
        pending_cache_ = {};
        ++epoch_;
        if (notify && notify_)
            notify_(session_);
    }
    void fail(const std::string& code, const std::string& message) {
        failure_ = error { code, message, {}, {}, {}, {}, {}, connecting_ };
        if (transaction_ && phase_ != phase::tx_begin && phase_ != phase::tx_commit)
            failure_->statement_index = statement_index_ + 1;
        results_.clear();
        retire();
        complete();
    }
    void wait(bool read, bool write, bool connect_poll = false) {
        detach();
        auto fd = library().PQsocket(conn_);
        if (fd < 0) {
            fail("SOCKET", "libpq has no socket");
            return;
        }
        asio::error_code ec;
#ifdef _WIN32
        if (!readiness_.is_open()) {
            auto event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!event) {
                fail("SOCKET", "cannot create socket readiness event");
                return;
            }
            readiness_.assign(event, ec);
            if (ec) {
                CloseHandle(event);
                fail("SOCKET", ec.message());
                return;
            }
        }
        auto socket = static_cast<SOCKET>(fd);
        long mask = FD_CLOSE | (read ? FD_READ : 0) | (write ? FD_WRITE : 0)
            | (connect_poll ? FD_CONNECT : 0);
        if (WSAEventSelect(socket, readiness_.native_handle(), mask) == SOCKET_ERROR) {
            fail(
                "SOCKET",
                "cannot subscribe to socket readiness: " + std::to_string(WSAGetLastError())
            );
            return;
        }
        watched_socket_ = socket;
#else
        readiness_.assign(
            asio::ip::tcp::v4(),
            static_cast<asio::ip::tcp::socket::native_handle_type>(fd),
            ec
        );
        if (ec) {
            fail("SOCKET", "cannot watch libpq socket: " + ec.message());
            return;
        }
#endif
        auto self = shared_from_this();
        auto epoch = epoch_;
        auto id = wait_id_;
        auto handler = [self, epoch, id, connect_poll](const asio::error_code& err) {
            if (!self->active(epoch) || id != self->wait_id_)
                return;
#ifdef _WIN32
            WSANETWORKEVENTS events {};
            WSAEnumNetworkEvents(self->watched_socket_, self->readiness_.native_handle(), &events);
            int connect_error =
                (events.lNetworkEvents & FD_CONNECT) ? events.iErrorCode[FD_CONNECT_BIT] : 0;
#endif
            self->detach();
            self->guard([&] {
                if (err) {
                    self->fail("SOCKET", "socket readiness failed: " + err.message());
                    return;
                }
#ifdef _WIN32
                // Winsock records connect errors in FD_CONNECT instead of
                // SO_ERROR when event notification is enabled. Do not let
                // PQconnectPoll mistake that socket for a successful connect.
                if (connect_poll && connect_error) {
                    self->next_address("TCP connect failed: " + std::to_string(connect_error));
                    return;
                }
#endif
                if (connect_poll)
                    self->poll_connect();
                else
                    self->exchange();
            });
        };
#ifdef _WIN32
        // A connect can finish (including refusal) before WSAEventSelect was
        // installed. FD_CONNECT is edge-triggered; close that registration race
        // with one nonblocking readiness check, not a periodic polling loop.
        fd_set reads, writes, errors;
        FD_ZERO(&reads);
        FD_ZERO(&writes);
        FD_ZERO(&errors);
        if (read)
            FD_SET(socket, &reads);
        if (write)
            FD_SET(socket, &writes);
        FD_SET(socket, &errors);
        timeval immediate {};
        int ready =
            ::select(0, read ? &reads : nullptr, write ? &writes : nullptr, &errors, &immediate);
        if (ready > 0)
            asio::post(io_, [handler] { handler({}); });
        else if (ready < 0)
            fail("SOCKET", "socket readiness check failed");
        else
            readiness_.async_wait(handler);
#else
        if (read)
            readiness_.async_wait(asio::ip::tcp::socket::wait_read, handler);
        if (write)
            readiness_.async_wait(asio::ip::tcp::socket::wait_write, handler);
#endif
    }
    void start_connect() {
        std::vector<const char*> keys, values;
        for (const auto& [k, v]: options_) {
            keys.push_back(k.c_str());
            values.push_back(v.c_str());
        }
        keys.push_back(nullptr);
        values.push_back(nullptr);
        conn_ = library().PQconnectStartParams(keys.data(), values.data(), 0);
        if (!conn_) {
            fail("ERROR", "libpq could not allocate connection");
            return;
        }
        poll_connect();
    }
    void next_address(const std::string& message) {
        if (++address_index_ >= addresses_.size()) {
            fail("SOCKET", message);
            return;
        }
        detach();
        if (conn_) {
            library().PQfinish(conn_);
            conn_ = nullptr;
        }
        options_["hostaddr"] = addresses_[address_index_];
        // Keep the same operation deadline and hostname/TLS identity. This is
        // connection establishment only, never replay of an application SQL.
        auto self = shared_from_this();
        auto epoch = epoch_;
        asio::post(io_, [self, epoch] {
            if (self->active(epoch))
                self->guard([&] { self->start_connect(); });
        });
    }
    void poll_connect() {
        switch (library().PQconnectPoll(conn_)) {
            case PGRES_POLLING_READING:
                wait(true, false, true);
                return;
            case PGRES_POLLING_WRITING:
                wait(false, true, true);
                return;
            case PGRES_POLLING_OK:
                if (library().PQsetnonblocking(conn_, 1) != 0) {
                    fail("SOCKET", library().PQerrorMessage(conn_));
                    return;
                }
                options_.clear();
                complete();
                return;
            default:
                next_address(library().PQerrorMessage(conn_));
                return;
        }
    }
    void database_error(PGresult* result) {
        auto field = [result](int code) {
            auto p = library().PQresultErrorField(result, code);
            return std::string(p ? p : "");
        };
        if (!failure_)
            failure_ = error { "DB",
                               field(PG_DIAG_MESSAGE_PRIMARY),
                               field(PG_DIAG_SQLSTATE),
                               field(PG_DIAG_MESSAGE_DETAIL),
                               field(PG_DIAG_MESSAGE_HINT),
                               field(PG_DIAG_CONSTRAINT_NAME),
                               field(PG_DIAG_TABLE_NAME) };
        if (transaction_ && phase_ != phase::tx_begin && phase_ != phase::tx_commit)
            failure_->statement_index = statement_index_ + 1;
        results_.clear();
    }
    void exchange() {
        auto& pq = library();
        if (!pq.PQconsumeInput(conn_)) {
            fail("SOCKET", pq.PQerrorMessage(conn_));
            return;
        }
        int flushing = pq.PQflush(conn_);
        if (flushing < 0) {
            fail("SOCKET", pq.PQerrorMessage(conn_));
            return;
        }
        if (flushing > 0) {
            wait(true, true);
            return;
        }
        // Bound callback work, otherwise a large buffered result can starve
        // timers and all other services sharing this worker.
        for (int quota = 0; quota < 128; ++quota) {
            if (pq.PQisBusy(conn_)) {
                wait(true, false);
                return;
            }
            result_ptr result(pq.PQgetResult(conn_));
            if (!result) {
                // Yield between wire phases as well as row chunks; no recursive chain of
                // cached statements can monopolize this worker or outrun the deadline.
                auto self = shared_from_this();
                auto epoch = epoch_;
                asio::post(io_, [self, epoch] {
                    if (self->active(epoch))
                        self->guard([&] { self->wire_complete(); });
                });
                return;
            }
            auto status = pq.PQresultStatus(result.get());
            if (status == PGRES_FATAL_ERROR || status == PGRES_NONFATAL_ERROR) {
                database_error(result.get());
                continue; // drain before reuse
            }
            if (status != PGRES_SINGLE_TUPLE && status != PGRES_TUPLES_OK
                && status != PGRES_COMMAND_OK && status != PGRES_EMPTY_QUERY)
            {
                fail(
                    "UNSUPPORTED",
                    "COPY/pipeline responses are not supported by this API; connection discarded"
                );
                return;
            }
            if (failure_)
                continue;
            if (phase_ != phase::execute && phase_ != phase::cached_execute)
                continue; // BEGIN/COMMIT/prepare/eviction never become user results
            auto count = static_cast<size_t>(pq.PQntuples(result.get()));
            rows_ += count;
            if (max_rows_ && rows_ > max_rows_) {
                fail("LIMIT", "result exceeded max_rows");
                return;
            }
            for (int col = 0; col < pq.PQnfields(result.get()); ++col) {
                for (int row = 0; row < static_cast<int>(count); ++row) {
                    bytes_ += static_cast<size_t>(pq.PQgetlength(result.get(), row, col));
                    if (max_bytes_ && bytes_ > max_bytes_) {
                        fail("LIMIT", "result exceeded max_result_bytes");
                        return;
                    }
                }
            }
            if (!in_rows_) {
                results_.emplace_back();
                auto& output = results_.back();
                for (int col = 0; col < pq.PQnfields(result.get()); ++col)
                    output.columns.push_back({ pq.PQfname(result.get(), col),
                                               pq.PQftype(result.get(), col) });
            }
            auto& output = results_.back();
            for (int row = 0; row < static_cast<int>(count); ++row) {
                for (int col = 0; col < pq.PQnfields(result.get()); ++col) {
                    cell value;
                    if (!pq.PQgetisnull(result.get(), row, col)) {
                        value.offset = output.data.size();
                        value.length = static_cast<size_t>(pq.PQgetlength(result.get(), row, col));
                        output.data.append(pq.PQgetvalue(result.get(), row, col), value.length);
                    }
                    output.cells.push_back(value);
                }
                ++output.row_count;
            }
            in_rows_ = status == PGRES_SINGLE_TUPLE;
            if (!in_rows_) {
                output.command = pq.PQcmdStatus(result.get());
                output.affected = pq.PQcmdTuples(result.get());
            }
        }
        auto self = shared_from_this();
        auto epoch = epoch_;
        asio::post(io_, [self, epoch] {
            if (self->active(epoch))
                self->guard([&] { self->exchange(); });
        });
    }

    asio::io_context& io_;
    asio::ip::tcp::resolver resolver_;
#ifdef _WIN32
    asio::windows::object_handle readiness_;
    SOCKET watched_socket_ = INVALID_SOCKET;
#else
    asio::ip::tcp::socket readiness_;
#endif
    asio::steady_timer timer_;
    notify_fn notify_;
    PGconn* conn_ = nullptr;
    std::map<std::string, std::string> options_;
    std::vector<std::string> addresses_;
    size_t address_index_ = 0;
    std::vector<result_set> results_;
    command command_ = command::query;
    phase phase_ = phase::execute;
    bool transaction_ = false, in_rows_ = false, committed_ = false;
    size_t statement_index_ = 0;
    statement current_;
    std::vector<statement> statements_;
    std::string explicit_name_;
    size_t cache_capacity_;
    uint64_t statement_sequence_ = 0;
    std::list<cache_entry> lru_;
    std::unordered_map<std::string, std::list<cache_entry>::iterator> cache_;
    cache_entry pending_cache_;
    std::optional<error> failure_;
    bool busy_ = false, ready_ = false, connecting_ = false;
    int64_t session_ = 0;
    uint64_t epoch_ = 0, wait_id_ = 0;
    size_t rows_ = 0, bytes_ = 0, max_rows_ = 0, max_bytes_ = 0;
};
} // namespace moon::pq
