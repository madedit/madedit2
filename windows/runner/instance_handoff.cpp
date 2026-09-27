#include "instance_handoff.h"

// winsock2.h must precede windows.h.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <cerrno>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include "utils.h"

namespace {

// -- tiny JSON helpers (the lock file is written by us, so a minimal
//    field scan is enough; anything unexpected just fails the handoff) --

bool FindInt(const std::string& json, const char* key, long long* out) {
  std::string needle = std::string("\"") + key + "\":";
  size_t p = json.find(needle);
  if (p == std::string::npos) return false;
  p += needle.size();
  while (p < json.size() && json[p] == ' ') p++;
  size_t end = p;
  while (end < json.size() && (isdigit(static_cast<unsigned char>(json[end])) ||
                               json[end] == '-')) {
    end++;
  }
  if (end == p) return false;
  // Not std::stoll: it throws on overflow ("port": 99999999999999999999) or a
  // lone '-', and wWinMain has no handler -- the process died before the
  // Flutter engine existed, on EVERY launch, until the lock file was deleted
  // by hand (the Dart side's "bad lock = claim it ourselves" never ran).
  const std::string digits = json.substr(p, end - p);
  errno = 0;
  char* stop = nullptr;
  const long long v = std::strtoll(digits.c_str(), &stop, 10);
  if (errno == ERANGE || stop == digits.c_str() || *stop != '\0') return false;
  *out = v;
  return true;
}

bool FindString(const std::string& json, const char* key, std::string* out) {
  std::string needle = std::string("\"") + key + "\":\"";
  size_t p = json.find(needle);
  if (p == std::string::npos) return false;
  p += needle.size();
  size_t end = json.find('"', p);
  if (end == std::string::npos) return false;
  *out = json.substr(p, end - p);
  return true;
}

std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof buf, "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

// The instance that wrote the lock: still running? A terminated process
// stays openable while something holds a handle to it, so the exit code is
// what decides. Access denied (an elevated primary) counts as alive.
bool ProcessAlive(DWORD pid) {
  HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (h == nullptr) return ::GetLastError() == ERROR_ACCESS_DENIED;
  DWORD code = 0;
  BOOL ok = ::GetExitCodeProcess(h, &code);
  ::CloseHandle(h);
  return !ok || code == STILL_ACTIVE;
}

std::wstring ExeDir() {
  wchar_t buf[MAX_PATH];
  DWORD n = ::GetModuleFileNameW(nullptr, buf, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return L"";
  std::wstring path(buf, n);
  size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"" : path.substr(0, slash);
}

std::wstring AbsolutePath(const std::wstring& p) {
  wchar_t buf[32768];
  DWORD n = ::GetFullPathNameW(p.c_str(), 32768, buf, nullptr);
  if (n == 0 || n >= 32768) return p;
  return std::wstring(buf, n);
}

// Connect with a bounded wait (a live port answers at once; this only
// guards against something odd sitting on the port).
bool ConnectLoopback(SOCKET s, int port, int timeout_ms) {
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<u_short>(port));
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  u_long nonblocking = 1;
  ::ioctlsocket(s, FIONBIO, &nonblocking);
  int r = ::connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof addr);
  if (r == SOCKET_ERROR && ::WSAGetLastError() != WSAEWOULDBLOCK) return false;
  if (r == SOCKET_ERROR) {
    fd_set w;
    FD_ZERO(&w);
    FD_SET(s, &w);
    fd_set e;
    FD_ZERO(&e);
    FD_SET(s, &e);
    timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    if (::select(0, nullptr, &w, &e, &tv) <= 0) return false;
    if (FD_ISSET(s, &e)) return false;
  }
  u_long blocking = 0;
  ::ioctlsocket(s, FIONBIO, &blocking);
  return true;
}

}  // namespace

bool TryHandoffToRunningInstance(const std::vector<std::wstring>& file_args) {
  std::wstring dir = ExeDir();
  if (dir.empty()) return false;
  std::ifstream lock(dir + L"\\settings\\instance.lock", std::ios::binary);
  if (!lock) return false;
  std::stringstream ss;
  ss << lock.rdbuf();
  const std::string json = ss.str();

  long long port = 0, pid = 0;
  std::string token;
  if (!FindInt(json, "port", &port) || !FindString(json, "token", &token)) {
    return false;
  }
  if (port <= 0 || port > 65535) return false;
  if (FindInt(json, "pid", &pid)) {
    if (!ProcessAlive(static_cast<DWORD>(pid))) return false;  // stale lock
    // The primary is a background process and may not raise its own window
    // (SetForegroundWindow is refused); this fresh process has the right
    // and passes it on - same as the Dart handshake does.
    ::AllowSetForegroundWindow(static_cast<DWORD>(pid));
  }

  std::string body = "{\"token\":\"" + JsonEscape(token) + "\",\"args\":[";
  for (size_t i = 0; i < file_args.size(); i++) {
    if (i) body += ',';
    body += '"' + JsonEscape(Utf8FromUtf16(AbsolutePath(file_args[i]).c_str())) +
            '"';
  }
  body += "]}\n";

  WSADATA wsa;
  if (::WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
  bool accepted = false;
  SOCKET s = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s != INVALID_SOCKET) {
    if (ConnectLoopback(s, static_cast<int>(port), 800)) {
      DWORD rcv_timeout = 2000;
      ::setsockopt(s, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&rcv_timeout),
                   sizeof rcv_timeout);
      const char* p = body.data();
      size_t left = body.size();
      bool sent = true;
      while (left > 0) {
        int n = ::send(s, p, static_cast<int>(left), 0);
        if (n <= 0) {
          sent = false;
          break;
        }
        p += n;
        left -= n;
      }
      if (sent) {
        std::string reply;
        char buf[64];
        while (reply.find('\n') == std::string::npos && reply.size() < 256) {
          int n = ::recv(s, buf, sizeof buf, 0);
          if (n <= 0) break;
          reply.append(buf, n);
        }
        accepted = reply.rfind("ok", 0) == 0;
      }
    }
    ::closesocket(s);
  }
  ::WSACleanup();
  return accepted;
}
