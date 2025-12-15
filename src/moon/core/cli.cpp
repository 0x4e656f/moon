#include "cli.h"
#include "message.hpp"
#include "worker.h"
#include "server.h"

#if TARGET_PLATFORM == PLATFORM_WINDOWS
#include <Psapi.h>
#pragma comment(lib,"psapi.lib")
#pragma comment(lib,"Winmm.lib")
#endif

namespace moon {

cli::cli()
{
}

cli::~cli()
{
    running_ = false;
    if (cliThread_) {
        //if (cliThread_->joinable()) {
        //    cliThread_->join();
        //}
        //delete cliThread_;
        cliThread_ = nullptr;
    }

#if TARGET_PLATFORM == PLATFORM_WINDOWS
    if (printSysInfoThread_) {
        if (printSysInfoThread_->joinable()) {
            printSysInfoThread_->join();
        }
        delete printSysInfoThread_;
        printSysInfoThread_ = nullptr;
    }
#endif
}

void cli::Init(server* s, const char* serverName)
{
    server_ = s;
    if (serverName != nullptr)
    {
        serverName_ = serverName;
    }

    running_ = true;
    cliThread_ = new std::thread(std::bind(&cli::CLIThread_, this));
#if TARGET_PLATFORM == PLATFORM_WINDOWS
    printSysInfoThread_ = new std::thread(std::bind(&cli::PrintSystemInfo_, this));
#endif
}

void cli::PrintMemStats_()
{
#ifdef MOON_ENABLE_MIMALLOC
#include "mimalloc.h"
    std::string stats;
    stats.append("mimalloc memory stats:\n");
    auto fn = [](const char* msg, void* arg)
    {
        auto p = static_cast<std::string*>(arg);
        p->append(msg);
    };

    mi_collect(true);
    mi_stats_print_out(fn, &stats);
    CONSOLE_INFO(stats.data());
#endif
}

void cli::HandleCLICommand_(const std::vector<std::string>& commands)
{
    if (commands.empty())
        return;

    const std::string& cmd = commands[0];
    if (cmd == "help")
    {
        std::ostringstream oss;
        oss << "Available commands:\n"
            << "  help       Show help\n"
            << "  exit       Quit the terminal\n"
            << "  mem        Print memory stats\n"
            << "  info       Show info\n"
            << "  log <n>    Set log level\n";
        CONSOLE_INFO(oss.str().c_str());
    }
    else if (cmd == "exit")
    {
        server_->stop(0);
    }
    else if (cmd == "mem")
    {
        PrintMemStats_();
    }
    else if (cmd == "info")
    {
        CONSOLE_INFO("%s", server_->info().c_str());
    }
    else if (cmd == "log")
    {
        if (commands.size() >= 2)
        {
            auto level = moon::string_convert<int>(commands[1]);
            moon::log::instance().set_level((LogLevel)level);
        }
    }
    else if (cmd == "cmd")
    {
        std::string realCmd = "test";
        auto buf = moon::buffer::make_unique();
        buf->write_back({ realCmd.c_str(), realCmd.length() });
        server_->send(0, BOOTSTRAP_ADDR, std::move(buf), 0, 14);
    }
    else
    {
        CONSOLE_INFO("Unknown command: %s\n", cmd.c_str());
    }
}

void cli::HandleCLICommand_(const std::string& command)
{
    if (command.empty())
        return;

    if (command == "mem")
    {
        PrintMemStats_();
    }
    else
    {
        auto buf = moon::buffer::make_unique();
        buf->write_back({ command.c_str(), command.length() });
        server_->send(0, BOOTSTRAP_ADDR, std::move(buf), 0, 100);
    }
}

void cli::PrintSystemInfo_()
{
#if TARGET_PLATFORM == PLATFORM_WINDOWS
    while (running_)
    {
        if (server_->get_state() != state::ready)
        {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            continue;
        }

        //�ڴ�
        HANDLE handle = GetCurrentProcess();
        PROCESS_MEMORY_COUNTERS pmc;
        GetProcessMemoryInfo(handle, &pmc, sizeof(pmc));

        //cpu
        SYSTEM_INFO info;
        GetSystemInfo(&info);

        FILETIME idleTime;
        FILETIME kernelTime;
        FILETIME userTime;

        GetSystemTimes(&idleTime, &kernelTime, &userTime);

        __int64 idle = CompareFileTime(&preidleTime_, &idleTime);
        __int64 kernel = CompareFileTime(&prekernelTime_, &kernelTime);
        __int64 user = CompareFileTime(&preuserTime_, &userTime);

        __int64 cpuUseage = 0;
        __int64 cpuidle = 0;
        if (kernel + user != 0)
        {
            cpuUseage = (kernel + user - idle) * 100 / (kernel + user);
            cpuidle = (idle) * 100 / (kernel + user);
        }

        preidleTime_ = idleTime;
        prekernelTime_ = kernelTime;
        preuserTime_ = userTime;

        auto mem = pmc.WorkingSetSize / 1024 / 1024;
        auto totalMem = pmc.PeakWorkingSetSize / 1024 / 1024;
        auto cpus = info.dwNumberOfProcessors;

        static char title[128];
        static char timeBuf[24];
        time::milltimestamp(time::now(), timeBuf, 24);
        wsprintf(title,
            "%s[Memory:%d/%dM][CPU:%d, usage: %.2d%%][ServerTime:%s]",
            serverName_.c_str(),
            mem, totalMem,
            cpus, cpuUseage,
            timeBuf);
        SetConsoleTitle(title);
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
    }
    CONSOLE_INFO("Quit SystemInfo thread!\n");
#endif
}

buffer cli::MakeLogBuffer_(bool stdOut)
{
    auto buf = buffer{ 25 };
    auto it = buf.begin();
    *(it++) = static_cast<char>(stdOut);
    *(it++) = static_cast<char>(LogLevel::Info);
    buf.commit(2);
    return buf;
}

void cli::CLIThread_()
{
    std::string line;
    while (running_)
    {
        if (server_->get_state() != state::ready)
        {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            continue;
        }
        auto buffer = MakeLogBuffer_();
        buffer.write_back(">");
        moon::log::instance().push_line(std::move(buffer));

        if (!std::getline(std::cin, line))
        {
            // 输入流被关闭，保留循环但避免挂死
            auto warn = MakeLogBuffer_();
            warn.write_back("[warning] 标准输入读取失败，可能是 Ctrl+D");
            moon::log::instance().push_line(std::move(warn));

            std::this_thread::sleep_for(std::chrono::seconds(1));
            continue;
        }

        if (!line.empty())
        {
            auto buffer = MakeLogBuffer_(false);
            buffer.write_back(line);
            moon::log::instance().push_line(std::move(buffer));

            //std::vector<std::string> commands = moon::split<std::string>(line, " ");
            HandleCLICommand_(line);
        }
        
    }
    CONSOLE_INFO("Quit CLI thread!\n");
}

} // namespace moon
