// Real prebuilt libpq against an in-process, loopback-only wire stub.
// This is not a PostgreSQL server: it cannot execute SQL or access a database.
#include "libpq/pq_connection.hpp"
#include <array>
#include <deque>
#include <iostream>

using asio::ip::tcp;
using moon::pq::connection;
static void check(bool value, const char* why) {
    if (!value)
        throw std::runtime_error(why);
}
static std::string i32(uint32_t n) {
    return { char(n >> 24), char(n >> 16), char(n >> 8), char(n) };
}
static std::string i16(uint16_t n) {
    return { char(n >> 8), char(n) };
}
static uint32_t number(const char* p) {
    return (uint32_t(uint8_t(p[0])) << 24) | (uint32_t(uint8_t(p[1])) << 16)
        | (uint32_t(uint8_t(p[2])) << 8) | uint8_t(p[3]);
}
static std::string z(const std::string& s) {
    return s + '\0';
}
static std::string frame(char type, const std::string& payload) {
    return type + i32(uint32_t(payload.size() + 4)) + payload;
}

struct wire_stats {
    std::map<std::string, size_t> parses, executions;
    size_t evictions = 0;
    std::vector<std::string> order;
    bool fail_commit = false, fail_rollback = false;
};
struct peer: std::enable_shared_from_this<peer> {
    tcp::socket socket;
    std::array<char, 5> header {};
    std::vector<char> body;
    std::deque<std::string> writes;
    std::string sql;
    bool bound = false, parsed = false;
    char tx = 'I';
    std::string name, wire_error;
    std::map<std::string, std::string> prepared;
    wire_stats& stats;
    explicit peer(tcp::socket s, wire_stats& stats): socket(std::move(s)), stats(stats) {}
    void write(std::string data) {
        writes.push_back(std::move(data));
        if (writes.size() == 1)
            flush();
    }
    void flush() {
        auto self = shared_from_this();
        asio::async_write(
            socket,
            asio::buffer(writes.front()),
            [self](asio::error_code ec, size_t) {
                if (ec)
                    return;
                self->writes.pop_front();
                if (!self->writes.empty())
                    self->flush();
            }
        );
    }
    void start() {
        auto self = shared_from_this();
        asio::async_read(
            socket,
            asio::buffer(header.data(), 4),
            [self](asio::error_code ec, size_t) {
                if (ec)
                    return;
                auto length = number(self->header.data());
                check(length >= 8 && length < 65536, "bad mock startup size");
                self->body.resize(length - 4);
                asio::async_read(
                    self->socket,
                    asio::buffer(self->body),
                    [self](asio::error_code ec2, size_t) {
                        if (ec2)
                            return;
                        if (number(self->body.data()) == 80877103) {
                            self->write("N");
                            self->start();
                            return;
                        }
                        check(number(self->body.data()) == 196608, "unexpected protocol");
                        self->write(
                            frame('R', i32(0)) + frame('S', z("client_encoding") + z("UTF8"))
                            + frame('S', z("server_version") + z("18.6"))
                            + frame('S', z("standard_conforming_strings") + z("on"))
                            + frame('K', i32(123) + i32(456)) + frame('Z', "I")
                        );
                        self->read();
                    }
                );
            }
        );
    }
    void read() {
        auto self = shared_from_this();
        asio::async_read(socket, asio::buffer(header), [self](asio::error_code ec, size_t) {
            if (ec)
                return;
            auto length = number(self->header.data() + 1);
            check(length >= 4 && length <= 8 * 1024 * 1024, "bad mock message size");
            self->body.resize(length - 4);
            asio::async_read(
                self->socket,
                asio::buffer(self->body),
                [self](asio::error_code ec2, size_t) {
                    if (ec2)
                        return;
                    self->message();
                    self->read();
                }
            );
        });
    }
    void message() {
        const auto type = header[0];
        if (type == 'P') {
            name = std::string(body.data());
            sql = std::string(body.data() + name.size() + 1);
            parsed = true;
            ++stats.parses[sql];
            if (sql != "SELECT parse_error")
                prepared[name] = sql;
        } else if (type == 'B') {
            const auto portal = std::string(body.data());
            const auto statement = std::string(body.data() + portal.size() + 1);
            auto found = prepared.find(statement);
            if (found == prepared.end())
                wire_error = "26000";
            else
                sql = found->second;
            bound = true;
        } else if (type == 'S') {
            respond(false);
            parsed = bound = false;
            wire_error.clear();
        } else if (type == 'Q') {
            sql = std::string(body.data());
            respond(true);
        }
    }
    void respond(bool simple) {
        const auto tag = sql.compare(0, 7, "SELECT ") == 0 ? sql.substr(7) : sql;
        if (bound || simple) {
            ++stats.executions[sql];
            stats.order.push_back(sql);
        }
        if ((bound || simple) && tag == "timeout")
            return;
        if ((bound || simple) && tag == "disconnect") {
            asio::error_code ec;
            socket.close(ec);
            return;
        }
        std::string response = !simple && parsed ? frame('1', "") : "";
        if (!wire_error.empty() || tag == "parse_error") {
            if (tx == 'T')
                tx = 'E';
            write(
                frame(
                    'E',
                    z("SERROR") + z("C" + (wire_error.empty() ? std::string("42601") : wire_error))
                        + z("Mmock preparation error") + '\0'
                )
                + frame('Z', std::string(1, tx))
            );
            return;
        }
        if (!simple && !bound) {
            write(response + frame('Z', std::string(1, tx)));
            return;
        }
        if (!simple)
            response += frame('2', "");
        if (tag == "error") {
            response += frame(
                'E',
                std::string("SERROR\0C23505\0Mduplicate\0Ddetail\0nconstraint_name\0\0", 51)
            );
            if (tx == 'T')
                tx = 'E';
            write(response + frame('Z', std::string(1, tx)));
            return;
        }
        if (tag == "copy") {
            write(response + frame('H', std::string("\0\0\0", 3)));
            return;
        }
        if (sql == "BEGIN" || sql == "COMMIT" || sql == "ROLLBACK"
            || sql.compare(0, 10, "DEALLOCATE") == 0)
        {
            if ((sql == "COMMIT" && stats.fail_commit)
                || (sql == "ROLLBACK" && stats.fail_rollback))
            {
                stats.fail_commit = stats.fail_rollback = false;
                tx = 'E';
                write(
                    response
                    + frame('E', z("SERROR") + z("C40001") + z("Mmock control failure") + '\0')
                    + frame('Z', "E")
                );
                return;
            }
            if (sql == "BEGIN")
                tx = 'T';
            else if (sql == "COMMIT" || sql == "ROLLBACK")
                tx = 'I';
            else if (sql == "DEALLOCATE ALL")
                prepared.clear();
            else {
                auto first = sql.find('"'), last = sql.rfind('"');
                check(first != std::string::npos && last > first, "bad cache eviction SQL");
                check(
                    prepared.erase(sql.substr(first + 1, last - first - 1)) == 1,
                    "evicted unknown statement"
                );
                ++stats.evictions;
            }
            write(response + frame('C', z(sql)) + frame('Z', std::string(1, tx)));
            return;
        }
        const std::string columns = i16(2) + z("value") + i32(0) + i16(0) + i32(20) + i16(8)
            + i32(0xffffffff) + i16(0) + z("null_value") + i32(0) + i16(0) + i32(25) + i16(0xffff)
            + i32(0xffffffff) + i16(0);
        const auto value = std::string("9223372036854775807");
        auto row = frame('D', i16(2) + i32(uint32_t(value.size())) + value + i32(0xffffffff));
        auto result = frame('T', columns) + row + row + frame('C', z("SELECT 2"));
        if (tag == "many") {
            result = frame('T', columns);
            for (int i = 0; i < 1000; ++i)
                result += row;
            result += frame('C', z("SELECT 1000"));
        }
        if (simple)
            result += frame('C', z("UPDATE 7"));
        write(response + result + frame('Z', std::string(1, tx)));
    }
};

int main(int argc, char** argv) {
    try {
        auto version = moon::pq::load_library(argc > 1 ? argv[1] : "");
        check(version >= 140000, "libpq 14+ required");
        std::cout << "Loaded prebuilt libpq " << version << '\n';
        asio::io_context io;
        wire_stats stats;
        tcp::acceptor listener(io, tcp::endpoint(asio::ip::address_v4::loopback(), 0));
        std::function<void()> accept;
        accept = [&] {
            listener.async_accept([&](asio::error_code ec, tcp::socket s) {
                if (!ec) {
                    std::make_shared<peer>(std::move(s), stats)->start();
                    accept();
                }
            });
        };
        accept();
        int notifications = 0;
        auto c = std::make_shared<connection>(io, [&](int64_t) { ++notifications; }, 2);
        auto wait = [&] {
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(8);
            while (!c->ready() && std::chrono::steady_clock::now() < until)
                io.run_one_for(std::chrono::milliseconds(50));
            check(c->ready(), "operation never completed");
        };
        std::map<std::string, std::string> options {
            { "host", "localhost" },
            { "hostaddr", "127.0.0.1" },
            { "port", std::to_string(listener.local_endpoint().port()) },
            { "user", "mock" },
            { "dbname", "mock" },
            { "sslmode", "disable" },
            { "gssencmode", "disable" }
        };
        auto connect = [&] {
            c->connect(options, 1, 6000);
            wait();
            if (c->failure())
                throw std::runtime_error(c->failure()->message);
            check(c->connected(), "not connected");
            c->consumed();
        };
        auto query = [&](const std::string& sql,
                         size_t rows = 10000,
                         size_t bytes = 1000000,
                         connection::command cmd = connection::command::query) {
            c->submit(cmd, sql, {}, "test", 2, 1000, rows, bytes);
            wait();
        };
        connect();
        query("rows");
        check(
            !c->failure() && c->results().size() == 1 && c->results()[0].row_count == 2,
            "compact row results not collected"
        );
        check(c->results()[0].cells[1].is_null(), "NULL lost");
        check(
            c->results()[0].value(c->results()[0].cells[0]) == "9223372036854775807",
            "bigint lost"
        );
        c->consumed();
        query("many");
        check(
            !c->failure() && c->results().size() == 1 && c->results()[0].row_count == 1000,
            "fairness yield lost rows"
        );
        c->consumed();
        query("rows", 100, 100000, connection::command::prepare);
        check(!c->failure(), "prepare failed");
        c->consumed();
        query("rows", 100, 100000, connection::command::prepared);
        check(
            !c->failure() && c->results()[0].row_count == 2,
            "explicit prepared execution failed"
        );
        c->consumed();
        query("rows", 100, 100000, connection::command::batch);
        check(!c->failure() && c->results().size() == 2, "batch results lost");
        c->consumed();
        query("SELECT cache_a");
        c->consumed();
        query("SELECT cache_a");
        c->consumed();
        check(
            stats.parses["SELECT cache_a"] == 1 && stats.executions["SELECT cache_a"] == 2,
            "cache did not avoid Parse"
        );
        query("SELECT cache_b");
        c->consumed();
        query("SELECT cache_a");
        c->consumed(); // refresh LRU
        query("SELECT cache_c");
        c->consumed();
        query("SELECT cache_b");
        c->consumed();
        check(
            stats.parses["SELECT cache_a"] == 1 && stats.parses["SELECT cache_b"] == 2,
            "cache eviction was not LRU"
        );
        check(
            c->cached_statements() == 2 && stats.evictions >= 2,
            "cache/server resources not bounded"
        );
        for (Oid type: { 20u, 25u, 20u }) {
            c->submit(
                connection::command::query,
                "SELECT typed_key",
                { { type, 0, std::string("1") } },
                "",
                2,
                1000,
                100,
                10000
            );
            wait();
            check(!c->failure(), "typed cache query failed");
            c->consumed();
        }
        check(stats.parses["SELECT typed_key"] == 2, "cache key must include parameter OIDs");
        auto transaction = [&](std::vector<moon::pq::statement> statements,
                               size_t rows = 100,
                               size_t bytes = 10000,
                               uint32_t timeout = 1000) {
            auto before = notifications;
            c->transaction(std::move(statements), 8, timeout, rows, bytes);
            wait();
            check(notifications == before + 1, "transaction notified Lua more than once");
        };
        transaction({ { "SELECT tx_a", {} }, { "SELECT tx_b", {} } });
        check(
            !c->failure() && c->results().size() == 2 && c->transaction_status() == PQTRANS_IDLE
                && c->transaction_committed(),
            "native transaction did not retain user results or commit"
        );
        check(stats.order.back() == "COMMIT", "transaction did not commit");
        c->consumed();
        transaction({ { "SELECT tx_a", {} }, { "SELECT error", {} } });
        check(
            c->failure() && c->failure()->sqlstate == "23505" && c->failure()->statement_index == 2,
            "transaction error lost original SQLSTATE/index"
        );
        check(
            stats.order.back() == "ROLLBACK" && c->connected()
                && c->transaction_status() == PQTRANS_IDLE,
            "transaction error was not rolled back before completion"
        );
        c->consumed();
        transaction({ { "SELECT parse_error", {} } });
        check(
            c->failure() && c->failure()->sqlstate == "42601" && c->failure()->statement_index == 1,
            "prepare error inside transaction not reported"
        );
        check(
            stats.executions["SELECT parse_error"] == 0 && stats.order.back() == "ROLLBACK",
            "failed prepare executed SQL or skipped rollback"
        );
        c->consumed();
        transaction({});
        check(!c->failure() && c->results().empty(), "empty transaction failed");
        c->consumed();
        auto before_validation = notifications;
        bool invalid_tx = false;
        try {
            c->transaction(
                { { "SELECT ok", {} }, { "/* nested /* x */ y */ -- skip\n COMMIT", {} } },
                8,
                1000,
                0,
                0
            );
        } catch (const std::exception&) {
            invalid_tx = true;
        }
        check(
            invalid_tx && notifications == before_validation && !c->busy(),
            "invalid transaction submitted partial SQL"
        );
        stats.fail_commit = true;
        transaction({ { "SELECT tx_a", {} } });
        check(
            c->failure() && c->failure()->sqlstate == "40001" && !c->connected()
                && !c->transaction_committed(),
            "failed commit retained connection or claimed success"
        );
        c->consumed();
        connect();
        stats.fail_rollback = true;
        transaction({ { "SELECT error", {} } });
        check(
            c->failure() && c->failure()->sqlstate == "23505" && !c->connected(),
            "failed rollback retained connection or replaced original error"
        );
        c->consumed();
        connect();
        transaction({ { "SELECT tx_a", {} }, { "SELECT tx_b", {} } }, 3);
        check(
            c->failure() && c->failure()->code == "LIMIT" && !c->connected(),
            "transaction cumulative row limit failed"
        );
        c->consumed();
        connect();
        transaction({ { "SELECT tx_a", {} }, { "SELECT tx_b", {} } }, 100, 50);
        check(
            c->failure() && c->failure()->code == "LIMIT" && !c->connected(),
            "transaction cumulative byte limit failed"
        );
        c->consumed();
        connect();
        transaction({ { "SELECT tx_a", {} }, { "SELECT timeout", {} } }, 100, 10000, 30);
        check(
            c->failure() && c->failure()->code == "TIMEOUT" && !c->connected(),
            "whole transaction deadline failed"
        );
        c->consumed();
        connect();
        query("SELECT stale");
        c->consumed();
        query("DEALLOCATE ALL");
        c->consumed();
        query("SELECT stale");
        check(
            c->failure() && c->failure()->sqlstate == "26000" && !c->connected(),
            "invalidated cached plan was reused"
        );
        check(stats.parses["SELECT stale"] == 1, "invalidated statement was silently retried");
        c->consumed();
        connect();
        query("error");
        check(
            c->failure() && c->failure()->sqlstate == "23505" && c->connected(),
            "database error handling failed"
        );
        c->consumed();
        query("rows");
        check(!c->failure(), "database error did not drain");
        c->consumed();
        query("rows", 1);
        check(c->failure()->code == "LIMIT" && !c->connected(), "row limit failed");
        c->consumed();
        connect();
        query("rows", 100, 1);
        check(c->failure()->code == "LIMIT", "byte limit failed");
        c->consumed();
        connect();
        query("copy");
        check(
            c->failure()->code == "UNSUPPORTED" && !c->connected(),
            "COPY must discard connection"
        );
        c->consumed();
        connect();
        query("disconnect");
        check(c->failure() && !c->connected(), "disconnect not detected");
        c->consumed();
        connect();
        c->submit(connection::command::query, "timeout", {}, "", 3, 30, 10, 1000);
        wait();
        check(
            c->failure()->code == "TIMEOUT" && !c->connected(),
            "deadline did not discard connection"
        );
        c->consumed();
        connect();
        c->submit(connection::command::query, "timeout", {}, "", 4, 500, 0, 0);
        bool busy = false;
        try {
            c->submit(connection::command::query, "rows", {}, "", 5, 500, 0, 0);
        } catch (const std::exception&) {
            busy = true;
        }
        check(busy, "concurrent query accepted");
        c->close();
        wait();
        check(c->failure()->code == "CLOSED", "close did not wake operation");
        c->consumed();
        c = std::make_shared<connection>(io, [&](int64_t) { ++notifications; }, 0);
        connect();
        query("SELECT no_cache");
        c->consumed();
        query("SELECT no_cache");
        c->consumed();
        check(
            c->cached_statements() == 0 && stats.parses["SELECT no_cache"] == 2,
            "cache capacity 0 did not disable caching"
        );
        c->close();
        options.erase("hostaddr");
        connect(); // Asio DNS, including IPv6-to-IPv4 fallback
        c->close(false);
        int before = notifications;
        io.poll();
        check(notifications == before, "stale callback notified twice");
        listener.close();
        io.stop();
        c.reset();
        std::cout << "libpq engine checks passed (prebuilt library + mock wire only)\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
