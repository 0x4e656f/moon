#pragma once
#include "common/concurrent_map.hpp"
#include "common/timer.hpp"
#include "config.hpp"
#include "log.hpp"
#include "worker.h"

namespace moon {
class cli final {

public:
    cli();
    ~cli();

    void Init(server* s, const char* serverName);
    static std::string s_ServerName;

private:
    void PrintSystemInfo_();
    void CLIThread_();
    void HandleCLICommand_(const std::vector<std::string>& commands);
    void HandleCLICommand_(const std::string& command);
    buffer MakeLogBuffer_(bool stdOut = true);
    void PrintMemStats_();

private:
    std::string serverName_ = "NONAME";
    server* server_ = nullptr;
    std::thread* cliThread_ = nullptr;
    std::atomic<bool> running_ = false;
#if TARGET_PLATFORM == PLATFORM_WINDOWS
    FILETIME preidleTime_;
    FILETIME prekernelTime_;
    FILETIME preuserTime_;
    std::thread* printSysInfoThread_ = nullptr;
#endif

};
}; // namespace moon
