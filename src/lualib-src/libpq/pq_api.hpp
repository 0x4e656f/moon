#pragma once
// The public headers are vendored unchanged. Load libpq only when requested,
// so the host and unrelated services do not acquire a mandatory DLL dependency.
#include "libpq/include/libpq-fe.h"
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <string>
#ifdef _WIN32
    #include <windows.h>
#else
    #include <dlfcn.h>
#endif

#define MOON_PQ_FUNCTIONS(X) \
    X(PQlibVersion) \
    X(PQisthreadsafe) X(PQconnectStartParams) X(PQconnectPoll) X(PQsocket) X(PQstatus) \
        X(PQsetnonblocking) X(PQerrorMessage) X(PQfinish) X(PQsendQueryParams) X(PQsendQuery) \
            X(PQconsumeInput) X(PQflush) X(PQisBusy) X(PQgetResult) X(PQclear) X(PQresultStatus) \
                X(PQresultErrorField) X(PQntuples) X(PQnfields) X(PQfname) X(PQftype) \
                    X(PQgetisnull) X(PQgetvalue) X(PQgetlength) X(PQcmdTuples) X(PQcmdStatus) \
                        X(PQtransactionStatus) X(PQsetSingleRowMode) X(PQsendPrepare) \
                            X(PQsendQueryPrepared)

namespace moon::pq {
struct api {
#define MOON_PQ_DECLARE(name) decltype(&::name) name = nullptr;
    MOON_PQ_FUNCTIONS(MOON_PQ_DECLARE)
#undef MOON_PQ_DECLARE
    void* handle = nullptr;
    std::string path;
};

inline api& library() {
    static api value;
    return value;
}

inline std::string library_path(const std::string& requested) {
#ifdef _WIN32
    return std::filesystem::absolute(
               std::filesystem::u8path(requested.empty() ? "clib/libpq/libpq.dll" : requested)
    )
        .lexically_normal()
        .u8string();
#else
    if (requested.empty())
        return "libpq.so.5";
    if (requested.find('/') == std::string::npos)
        return requested;
    return std::filesystem::absolute(requested).lexically_normal().string();
#endif
}

inline int load_library(const std::string& requested = {}) {
    static std::mutex mutex;
    std::lock_guard<std::mutex> guard(mutex);
    auto& current = library();
    if (current.handle) {
        if (!requested.empty() && library_path(requested) != current.path)
            throw std::runtime_error("libpq is already loaded from another path");
        return current.PQlibVersion();
    }
    api candidate;
    candidate.path = library_path(requested);
#ifdef _WIN32
    auto path = std::filesystem::u8path(candidate.path);
    candidate.handle = LoadLibraryExW(
        path.c_str(),
        nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
    );
    if (!candidate.handle)
        throw std::runtime_error(
            "cannot load libpq and its dependencies from " + candidate.path + " (Windows error "
            + std::to_string(GetLastError()) + ")"
        );
#else
    candidate.handle = dlopen(candidate.path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!candidate.handle)
        throw std::runtime_error(std::string("cannot load libpq: ") + dlerror());
#endif
    try {
#ifdef _WIN32
    #define MOON_PQ_LOAD(name) \
        candidate.name = reinterpret_cast<decltype(candidate.name)>( \
            GetProcAddress(static_cast<HMODULE>(candidate.handle), #name) \
        ); \
        if (!candidate.name) \
            throw std::runtime_error("libpq missing " #name);
#else
    #define MOON_PQ_LOAD(name) \
        candidate.name = \
            reinterpret_cast<decltype(candidate.name)>(dlsym(candidate.handle, #name)); \
        if (!candidate.name) \
            throw std::runtime_error("libpq missing " #name);
#endif
        MOON_PQ_FUNCTIONS(MOON_PQ_LOAD)
#undef MOON_PQ_LOAD
        if (candidate.PQlibVersion() < 140000 || candidate.PQisthreadsafe() != 1)
            throw std::runtime_error("libpq 14+ with thread safety is required");
    } catch (...) {
#ifdef _WIN32
        FreeLibrary(static_cast<HMODULE>(candidate.handle));
#else
        dlclose(candidate.handle);
#endif
        throw;
    }
    // Deliberately retain the library until process exit: PGresult deleters
    // and in-flight Asio handlers can outlive the Lua service loading it.
    current = std::move(candidate);
    return current.PQlibVersion();
}
} // namespace moon::pq
