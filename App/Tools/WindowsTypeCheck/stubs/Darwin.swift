// STAND-IN for the parts of Darwin the app uses (BSD sockets, POSIX files and processes, libproc): declarations only, for
// type-checking on Windows. typecheck.sh keeps the Windows C runtime from declaring its own POSIX-named aliases
// (-D_CRT_DECLARE_NONSTDC_NAMES=0, -D_CRT_NO_POSIX_ERROR_CODES), so these are the only stat, close, open, S_IFDIR,
// EWOULDBLOCK ... the app sees, laid out as a Mac lays them out. Names the C standard itself defines (errno, EAGAIN,
// SIGTERM, timespec, strerror) still come from the C runtime, as a Mac's do.
import ucrt

public typealias socklen_t = UInt32
public typealias sa_family_t = UInt8
public typealias in_port_t = UInt16
public typealias in_addr_t = UInt32
public typealias pid_t = Int32
public typealias id_t = UInt32
public typealias uid_t = UInt32
public typealias gid_t = UInt32
public typealias mode_t = UInt16
public typealias off_t = Int64
public typealias dev_t = Int32
public typealias ino_t = UInt64
public typealias nfds_t = UInt32
public typealias sigset_t = UInt32

public struct in_addr { public var s_addr: in_addr_t; public init() { s_addr = 0 }; public init(s_addr: in_addr_t) { self.s_addr = s_addr } }
public struct in6_addr { public var __u6_addr: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0); public init() {} }
public struct sockaddr {
    public var sa_len: UInt8, sa_family: sa_family_t
    public var sa_data: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)
    public init() { sa_len = 0; sa_family = 0; sa_data = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
}
public struct sockaddr_in {
    public var sin_len: UInt8, sin_family: sa_family_t, sin_port: in_port_t, sin_addr: in_addr
    public var sin_zero: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)
    public init() { sin_len = 0; sin_family = 0; sin_port = 0; sin_addr = in_addr(); sin_zero = (0, 0, 0, 0, 0, 0, 0, 0) }
}
public struct sockaddr_in6 {
    public var sin6_len: UInt8 = 0, sin6_family: sa_family_t = 0, sin6_port: in_port_t = 0, sin6_flowinfo: UInt32 = 0
    public var sin6_addr = in6_addr(), sin6_scope_id: UInt32 = 0
    public init() {}
}
public struct sockaddr_storage { public var ss_len: UInt8 = 0, ss_family: sa_family_t = 0; public init() {} }
public struct sockaddr_un {
    public var sun_len: UInt8 = 0, sun_family: sa_family_t = 0
    public var sun_path: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 0, 0, 0, 0, 0, 0)
    public init() {}
}
public struct addrinfo {
    public var ai_flags: Int32 = 0, ai_family: Int32 = 0, ai_socktype: Int32 = 0, ai_protocol: Int32 = 0
    public var ai_addrlen: socklen_t = 0
    public var ai_canonname: UnsafeMutablePointer<CChar>? = nil
    public var ai_addr: UnsafeMutablePointer<sockaddr>! = nil
    public var ai_next: UnsafeMutablePointer<addrinfo>? = nil
    public init() {}
}
public struct ifaddrs {
    public var ifa_next: UnsafeMutablePointer<ifaddrs>?
    public var ifa_name: UnsafeMutablePointer<CChar>!
    public var ifa_flags: UInt32
    public var ifa_addr: UnsafeMutablePointer<sockaddr>!
    public var ifa_netmask: UnsafeMutablePointer<sockaddr>!
    public var ifa_dstaddr: UnsafeMutablePointer<sockaddr>!
    public var ifa_data: UnsafeMutableRawPointer!
}
public struct pollfd { public var fd: Int32, events: Int16, revents: Int16; public init(fd: Int32, events: Int16, revents: Int16) { self.fd = fd; self.events = events; self.revents = revents }; public init() { fd = 0; events = 0; revents = 0 } }

public var AF_INET: Int32 { 2 }
public var AF_INET6: Int32 { 30 }
public var AF_UNIX: Int32 { 1 }
public var SOCK_DGRAM: Int32 { 2 }
public var SOCK_STREAM: Int32 { 1 }
public var IPPROTO_IP: Int32 { 0 }
public var IPPROTO_UDP: Int32 { 17 }
public var IPPROTO_TCP: Int32 { 6 }
public var IP_MULTICAST_IF: Int32 { 9 }
public var IP_MULTICAST_TTL: Int32 { 10 }
public var IP_TOS: Int32 { 3 }
public var SOL_SOCKET: Int32 { 0xFFFF }
public var SO_BROADCAST: Int32 { 0x20 }
public var SO_NET_SERVICE_TYPE: Int32 { 0x1116 }
public var NET_SERVICE_TYPE_VO: Int32 { 7 }
public var SO_REUSEADDR: Int32 { 4 }
public var SO_ERROR: Int32 { 0x1007 }
public var SO_NOSIGPIPE: Int32 { 0x1022 }
public var SHUT_RDWR: Int32 { 2 }
public var F_SETFL: Int32 { 4 }
public var F_GETFL: Int32 { 3 }
public var F_GETFD: Int32 { 1 }
public var F_SETFD: Int32 { 2 }
public var F_DUPFD_CLOEXEC: Int32 { 67 }
public var FD_CLOEXEC: Int32 { 1 }
public var O_RDONLY: Int32 { 0 }
public var O_WRONLY: Int32 { 1 }
public var O_RDWR: Int32 { 2 }
public var O_NONBLOCK: Int32 { 4 }
public var O_APPEND: Int32 { 8 }
public var O_CREAT: Int32 { 0x200 }
public var O_TRUNC: Int32 { 0x400 }
public var O_EXCL: Int32 { 0x800 }
public var O_NOFOLLOW: Int32 { 0x100 }
public var O_CLOEXEC: Int32 { 0x1000000 }
public var O_DIRECTORY: Int32 { 0x100000 }
public var AT_FDCWD: Int32 { -2 }
public var AT_SYMLINK_NOFOLLOW: Int32 { 0x20 }
public var AT_REMOVEDIR: Int32 { 0x80 }
public var PATH_MAX: Int32 { 1024 }
public var NAME_MAX: Int32 { 255 }
public var INADDR_ANY: in_addr_t { 0 }
public var INET_ADDRSTRLEN: Int32 { 16 }
public var INET6_ADDRSTRLEN: Int32 { 46 }
public var IFF_LOOPBACK: Int32 { 8 }
public var IFF_POINTOPOINT: Int32 { 0x10 }
public var IFF_UP: Int32 { 1 }
public var IFF_RUNNING: Int32 { 0x40 }
public var EWOULDBLOCK: Int32 { 35 }
public var EINPROGRESS: Int32 { 36 }
public var ECONNREFUSED: Int32 { 61 }
public var ECONNRESET: Int32 { 54 }
public var ENOTCONN: Int32 { 57 }
public var ETIMEDOUT: Int32 { 60 }
public var EADDRINUSE: Int32 { 48 }
public var POLLIN: Int16 { 0x1 }
public var POLLOUT: Int16 { 0x4 }
public var POLLERR: Int16 { 0x8 }
public var POLLHUP: Int16 { 0x10 }
public var SIGKILL: Int32 { 9 }
public var SIGPIPE: Int32 { 13 }
public var SIGCONT: Int32 { 19 }
public var SIGCHLD: Int32 { 20 }
public var WNOHANG: Int32 { 1 }
public var WEXITED: Int32 { 4 }
public var WNOWAIT: Int32 { 0x20 }
public var CLD_EXITED: Int32 { 1 }
public var P_PID: idtype_t { idtype_t(1) }
public var RUSAGE_SELF: Int32 { 0 }

public func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 { 0 }
public func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 { 0 }
public func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int32 { 0 }
public func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { 0 }
public func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>!, _ len: UnsafeMutablePointer<socklen_t>!) -> Int32 { 0 }
public func getsockname(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>!, _ len: UnsafeMutablePointer<socklen_t>!) -> Int32 { 0 }
public func getpeername(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>!, _ len: UnsafeMutablePointer<socklen_t>!) -> Int32 { 0 }
public func sendto(_ fd: Int32, _ buffer: UnsafeRawPointer!, _ length: Int, _ flags: Int32, _ addr: UnsafePointer<sockaddr>!, _ len: socklen_t) -> Int { 0 }
public func recvfrom(_ fd: Int32, _ buffer: UnsafeMutableRawPointer!, _ length: Int, _ flags: Int32, _ addr: UnsafeMutablePointer<sockaddr>!,
                     _ len: UnsafeMutablePointer<socklen_t>!) -> Int { 0 }
public func send(_ fd: Int32, _ buffer: UnsafeRawPointer!, _ length: Int, _ flags: Int32) -> Int { 0 }
public func recv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer!, _ length: Int, _ flags: Int32) -> Int { 0 }
public func shutdown(_ fd: Int32, _ how: Int32) -> Int32 { 0 }
public func setsockopt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: UnsafeRawPointer!, _ len: socklen_t) -> Int32 { 0 }
public func getsockopt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: UnsafeMutableRawPointer!, _ len: UnsafeMutablePointer<socklen_t>!) -> Int32 { 0 }
public func getpeereid(_ fd: Int32, _ uid: UnsafeMutablePointer<uid_t>!, _ gid: UnsafeMutablePointer<gid_t>!) -> Int32 { 0 }
public func poll(_ fds: UnsafeMutablePointer<pollfd>!, _ nfds: nfds_t, _ timeout: Int32) -> Int32 { 0 }
public func close(_ fd: Int32) -> Int32 { 0 }
public func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ nbyte: Int) -> Int { 0 }
public func write(_ fd: Int32, _ buf: UnsafeRawPointer!, _ nbyte: Int) -> Int { 0 }
public func open(_ path: UnsafePointer<CChar>!, _ oflag: Int32) -> Int32 { 0 }
public func open(_ path: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32 { 0 }
public func openat(_ fd: Int32, _ path: UnsafePointer<CChar>!, _ oflag: Int32) -> Int32 { 0 }
public func openat(_ fd: Int32, _ path: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32 { 0 }
public func fcntl(_ fd: Int32, _ cmd: Int32, _ value: Int32) -> Int32 { 0 }
public func fcntl(_ fd: Int32, _ cmd: Int32) -> Int32 { 0 }
public func dup(_ fd: Int32) -> Int32 { 0 }
public func dup2(_ fd: Int32, _ fd2: Int32) -> Int32 { 0 }
public func pipe(_ fds: UnsafeMutablePointer<Int32>!) -> Int32 { 0 }
public func fchmod(_ fd: Int32, _ mode: mode_t) -> Int32 { 0 }
public func chmod(_ path: UnsafePointer<CChar>!, _ mode: mode_t) -> Int32 { 0 }
public func fsync(_ fd: Int32) -> Int32 { 0 }
public func unlink(_ path: UnsafePointer<CChar>!) -> Int32 { 0 }
public func rmdir(_ path: UnsafePointer<CChar>!) -> Int32 { 0 }
public func isatty(_ fd: Int32) -> Int32 { 0 }
public func strdup(_ s: UnsafePointer<CChar>!) -> UnsafeMutablePointer<CChar>! { nil }
public func unlinkat(_ fd: Int32, _ path: UnsafePointer<CChar>!, _ flag: Int32) -> Int32 { 0 }
public func linkat(_ fd1: Int32, _ path1: UnsafePointer<CChar>!, _ fd2: Int32, _ path2: UnsafePointer<CChar>!, _ flag: Int32) -> Int32 { 0 }
public func renameat(_ fd1: Int32, _ from: UnsafePointer<CChar>!, _ fd2: Int32, _ to: UnsafePointer<CChar>!) -> Int32 { 0 }
public func mkdirat(_ fd: Int32, _ path: UnsafePointer<CChar>!, _ mode: mode_t) -> Int32 { 0 }
public func inet_pton(_ af: Int32, _ src: UnsafePointer<CChar>!, _ dst: UnsafeMutableRawPointer!) -> Int32 { 0 }
public func inet_ntop(_ af: Int32, _ src: UnsafeRawPointer!, _ dst: UnsafeMutablePointer<CChar>!, _ size: socklen_t) -> UnsafePointer<CChar>! { nil }
public func inet_addr(_ cp: UnsafePointer<CChar>!) -> in_addr_t { 0 }
public func getaddrinfo(_ node: UnsafePointer<CChar>!, _ service: UnsafePointer<CChar>!, _ hints: UnsafePointer<addrinfo>!,
                        _ res: UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>?>!) -> Int32 { 0 }
public func freeaddrinfo(_ ai: UnsafeMutablePointer<addrinfo>!) {}
public func getifaddrs(_ list: UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>!) -> Int32 { 0 }
public func freeifaddrs(_ list: UnsafeMutablePointer<ifaddrs>!) {}
public func if_nametoindex(_ name: UnsafePointer<CChar>!) -> UInt32 { 0 }
public func getpid() -> pid_t { 0 }
public func getppid() -> pid_t { 0 }
public func getuid() -> uid_t { 0 }
public func geteuid() -> uid_t { 0 }
public func getgid() -> gid_t { 0 }
public func kill(_ pid: pid_t, _ sig: Int32) -> Int32 { 0 }
public func killpg(_ pgrp: pid_t, _ sig: Int32) -> Int32 { 0 }
public func usleep(_ useconds: UInt32) -> Int32 { 0 }

// Files: laid out as Darwin's stat is (timespec times, 64-bit sizes and inodes).
public struct stat {
    public var st_dev: Int32 = 0
    public var st_mode: mode_t = 0
    public var st_nlink: UInt16 = 0
    public var st_ino: UInt64 = 0
    public var st_uid: uid_t = 0
    public var st_gid: gid_t = 0
    public var st_rdev: Int32 = 0
    public var st_atimespec = timespec()
    public var st_mtimespec = timespec()
    public var st_ctimespec = timespec()
    public var st_birthtimespec = timespec()
    public var st_size: off_t = 0
    public var st_blocks: Int64 = 0
    public var st_blksize: Int32 = 0
    public var st_flags: UInt32 = 0
    public var st_gen: UInt32 = 0
    public init() {}
}
public var S_IFMT: mode_t { 0o170000 }
public var S_IFREG: mode_t { 0o100000 }
public var S_IFDIR: mode_t { 0o040000 }
public var S_IFLNK: mode_t { 0o120000 }
public var S_IRWXU: mode_t { 0o700 }
public var S_IRUSR: mode_t { 0o400 }
public var S_IWUSR: mode_t { 0o200 }
public var S_IXUSR: mode_t { 0o100 }
public var S_IRGRP: mode_t { 0o040 }
public var S_IWGRP: mode_t { 0o020 }
public var S_IXGRP: mode_t { 0o010 }
public var S_IROTH: mode_t { 0o004 }
public var S_IWOTH: mode_t { 0o002 }
public var S_IXOTH: mode_t { 0o001 }
public func lstat(_ path: UnsafePointer<CChar>!, _ value: UnsafeMutablePointer<stat>!) -> Int32 { -1 }
// (No stat(path, buf) function: Swift can't declare a function and a struct with one name; C imports can.)
public func fstat(_ fd: Int32, _ value: UnsafeMutablePointer<stat>!) -> Int32 { -1 }
public func fstatat(_ fd: Int32, _ path: UnsafePointer<CChar>!, _ value: UnsafeMutablePointer<stat>!, _ flag: Int32) -> Int32 { -1 }

// Resource use.
public struct timeval { public var tv_sec: Int = 0, tv_usec: Int32 = 0; public init() {}; public init(tv_sec: Int, tv_usec: Int32) { self.tv_sec = tv_sec; self.tv_usec = tv_usec } }
public struct rusage {
    public var ru_utime = timeval(), ru_stime = timeval()
    public var ru_maxrss: Int = 0, ru_ixrss: Int = 0, ru_idrss: Int = 0, ru_isrss: Int = 0, ru_minflt: Int = 0, ru_majflt: Int = 0
    public var ru_nswap: Int = 0, ru_inblock: Int = 0, ru_oublock: Int = 0, ru_msgsnd: Int = 0, ru_msgrcv: Int = 0, ru_nsignals: Int = 0
    public var ru_nvcsw: Int = 0, ru_nivcsw: Int = 0
    public init() {}
}
public func getrusage(_ who: Int32, _ usage: UnsafeMutablePointer<rusage>!) -> Int32 { 0 }

// Signals and child processes.
public struct idtype_t: RawRepresentable, Equatable { public var rawValue: UInt32; public init(_ v: UInt32) { rawValue = v }; public init(rawValue: UInt32) { self.rawValue = rawValue } }
public struct siginfo_t { public var si_signo: Int32 = 0, si_errno: Int32 = 0, si_code: Int32 = 0, si_pid: pid_t = 0, si_uid: uid_t = 0, si_status: Int32 = 0; public init() {} }
public func sigemptyset(_ set: UnsafeMutablePointer<sigset_t>!) -> Int32 { 0 }
public func sigfillset(_ set: UnsafeMutablePointer<sigset_t>!) -> Int32 { 0 }
public func sigaddset(_ set: UnsafeMutablePointer<sigset_t>!, _ signo: Int32) -> Int32 { 0 }
public func waitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>!, _ options: Int32) -> pid_t { 0 }
public func waitid(_ idtype: idtype_t, _ id: id_t, _ info: UnsafeMutablePointer<siginfo_t>!, _ options: Int32) -> Int32 { 0 }

// posix_spawn.
public typealias posix_spawn_file_actions_t = UnsafeMutableRawPointer
public typealias posix_spawnattr_t = UnsafeMutableRawPointer
public var POSIX_SPAWN_SETPGROUP: Int32 { 0x02 }
public var POSIX_SPAWN_SETSIGDEF: Int32 { 0x04 }
public var POSIX_SPAWN_SETSIGMASK: Int32 { 0x08 }
public var POSIX_SPAWN_START_SUSPENDED: Int32 { 0x80 }
public var POSIX_SPAWN_CLOEXEC_DEFAULT: Int32 { 0x4000 }
public func posix_spawn(_ pid: UnsafeMutablePointer<pid_t>!, _ path: UnsafePointer<CChar>!, _ fileActions: UnsafePointer<posix_spawn_file_actions_t?>!,
                        _ attr: UnsafePointer<posix_spawnattr_t?>!, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>!,
                        _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>!) -> Int32 { 0 }
public func posix_spawn_file_actions_init(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>!) -> Int32 { 0 }
public func posix_spawn_file_actions_destroy(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>!) -> Int32 { 0 }
public func posix_spawn_file_actions_addclose(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>!, _ fd: Int32) -> Int32 { 0 }
public func posix_spawn_file_actions_adddup2(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>!, _ fd: Int32, _ newfd: Int32) -> Int32 { 0 }
public func posix_spawn_file_actions_addopen(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>!, _ fd: Int32,
                                             _ path: UnsafePointer<CChar>!, _ oflag: Int32, _ mode: mode_t) -> Int32 { 0 }
public func posix_spawnattr_init(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>!) -> Int32 { 0 }
public func posix_spawnattr_destroy(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>!) -> Int32 { 0 }
public func posix_spawnattr_setflags(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>!, _ flags: Int16) -> Int32 { 0 }
public func posix_spawnattr_setpgroup(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>!, _ pgroup: pid_t) -> Int32 { 0 }
public func posix_spawnattr_setsigdefault(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>!, _ sigdefault: UnsafePointer<sigset_t>!) -> Int32 { 0 }
public func posix_spawnattr_setsigmask(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>!, _ sigmask: UnsafePointer<sigset_t>!) -> Int32 { 0 }

// libproc.
public var PROC_PIDTASKINFO: Int32 { 4 }
public var PROC_PIDTBSDINFO: Int32 { 3 }
public var PROC_PIDLISTFDS: Int32 { 1 }
public struct proc_taskinfo {
    public var pti_virtual_size: UInt64 = 0, pti_resident_size: UInt64 = 0, pti_total_user: UInt64 = 0, pti_total_system: UInt64 = 0
    public var pti_threads_user: UInt64 = 0, pti_threads_system: UInt64 = 0, pti_policy: Int32 = 0, pti_faults: Int32 = 0
    public var pti_pageins: Int32 = 0, pti_cow_faults: Int32 = 0, pti_messages_sent: Int32 = 0, pti_messages_received: Int32 = 0
    public var pti_syscalls_mach: Int32 = 0, pti_syscalls_unix: Int32 = 0, pti_csw: Int32 = 0, pti_threadnum: Int32 = 0
    public var pti_numrunning: Int32 = 0, pti_priority: Int32 = 0
    public init() {}
}
public struct proc_bsdinfo {
    public var pbi_flags: UInt32 = 0, pbi_status: UInt32 = 0, pbi_xstatus: UInt32 = 0, pbi_pid: UInt32 = 0, pbi_ppid: UInt32 = 0
    public var pbi_uid: uid_t = 0, pbi_gid: gid_t = 0, pbi_ruid: uid_t = 0, pbi_rgid: gid_t = 0, pbi_svuid: uid_t = 0, pbi_svgid: gid_t = 0
    public var pbi_pgid: UInt32 = 0, pbi_start_tvsec: UInt64 = 0, pbi_start_tvusec: UInt64 = 0, pbi_nfiles: UInt32 = 0
    public init() {}
}
public struct proc_fdinfo { public var proc_fd: Int32 = 0, proc_fdtype: UInt32 = 0; public init() {} }
public func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer!, _ buffersize: Int32) -> Int32 { 0 }
public func proc_listpgrppids(_ pgrpid: pid_t, _ buffer: UnsafeMutableRawPointer!, _ buffersize: Int32) -> Int32 { 0 }

public func setenv(_ name: UnsafePointer<CChar>!, _ value: UnsafePointer<CChar>!, _ overwrite: Int32) -> Int32 { 0 }
public func unsetenv(_ name: UnsafePointer<CChar>!) -> Int32 { 0 }
public func getdtablesize() -> Int32 { 256 }
