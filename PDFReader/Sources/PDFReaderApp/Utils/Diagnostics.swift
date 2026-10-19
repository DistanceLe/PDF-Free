import AppKit
import Darwin
import Foundation

// MARK: - 崩溃兜底要用的全局量
//
// ⚠️ 必须是**文件级 C 全局**（不是 `Diagnostics` 的属性）：
// 信号处理函数里不能碰 Swift 对象、不能分配内存、不能加锁 —— 那些在信号上下文里
// 都是未定义行为（可能直接死在 handler 里，连日志都留不下）。
// 所以只留一个 fd + 两块预先分配好的字符缓冲，handler 里只用 `write` / `strlcpy`。
nonisolated(unsafe) private var crashLogFD: Int32 = -1
nonisolated(unsafe) private let crashActivityBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
nonisolated(unsafe) private let crashLineBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
/// `backtrace` 的落点。**不能用 Swift 数组** —— 那个要分配堆内存。
nonisolated(unsafe) private let crashFrames =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)

/// 现场记录仪：把"真实使用时到底发生了什么"写进日志文件。
///
/// ## 为什么需要它
///
/// 有一批问题（拖动目录后卡顿、关闭时不提示保存）在探针环境里**复现不出来**：
/// 拖拽会话合成不出（要 `NSDraggingSession`），`NSAlert` 也点不了。
/// 探针只能证明"函数逻辑是对的"，证明不了"真实交互里到底发生了什么"。
///
/// 所以让 app 自己记：主线程卡了多久、卡的时候在干什么、关闭链路有没有被走到、
/// 拖放回调被调了多少次。
///
/// ## v1.3.53：这个记录仪本身**在出故障时留不下证据**，整个重做了一遍
///
/// 用户报"`合集2.3.pdf` 不管怎么打开，滚动一下就死"，而日志里**干干净净**：
/// 既没有崩溃遗言，也没有卡顿记录，就断在打开文件那一刻。原因是三条同时失效：
///
/// 1. **主线程看门狗本身在主线程上**（runloop observer）—— 主线程一卡死它自己也停了，
///    一个字都写不出来。这是最要命的：越需要它的时候它越不在；
/// 2. **`NSSetUncaughtExceptionHandler` 拦不到这类崩溃** —— 异常没人接时走的是
///    `std::terminate` → `abort`（系统崩溃报告里那一列 stack 写得很清楚），
///    而 uncaught handler 只在 `NSApplicationMain` 那层 `@try` 里才会被调用，根本没经过它；
/// 3. **日志是异步写的**（后台队列 + `FileHandle`）—— 进程被强制退出（用户卡急了
///    ⌘⌥Esc / `kill -9`）时，队列里还没落盘的内容**一起没了**。
///
/// 现在：看门狗搬到**后台线程**（主线程死了它照样活着写）、加**信号兜底**
///（SIGABRT/SIGSEGV… 直接写栈，不依赖任何 Objective-C 机制）、日志改成
/// **同步 `write(2)` 直写文件**（进程随时被杀都不丢）。
///
/// ## 成本控制
///
/// - 正常路径几乎零成本：慢轮次只在超过阈值时才动一次；一条日志 = 一次 `write`
///   （几微秒，日志量本来就低）；
/// - 拖放回调只做一次整数累加（`NSLock`，微秒级）；
/// - 日志超过 512KB 自动轮转，不会无限涨。
///
/// 日志位置在沙箱容器里，**不用记路径** —— 设置 → 诊断 里有「在访达中显示」按钮。
///
/// ## 总开关（v1.3.68）
///
/// **Release 构建默认关，Debug 构建默认开**（见 `defaultEnabled`），
/// 用户可以在「设置 → 诊断」里改，**改完立即生效、不用重启**。
///
/// 关掉之后这些统统不做（都是"平时一直在花时间"的东西）：
///
/// | 关掉的 | 原来在花什么 |
/// |---|---|
/// | 日志文件 | 连目录都不建、句柄都不开 —— 一个文件都不出现 |
/// | 主线程看门狗 | 那个 `CFRunLoopObserver` **每一轮 runloop 都会被调一次** |
/// | 卡死检测线程 | 后台每秒醒一次 |
/// | 鼠标事件监听 | 每次点击都要过一遍回调 |
/// | `record` / `measure` / `count` / `activity` | 直接 return，连一次 `write(2)` 都不发 |
///
/// ### 为什么崩溃兜底不跟着关
///
/// **信号 handler + 未捕获异常 handler 永远装着**（在 `init` 里装，不看开关）。
///
/// 理由很实在：它平时**一点开销都没有** —— 只在进程要死的那一刻才动一下，
/// 而它恰恰是"用户报崩溃"时唯一的证据来源。关掉它，问题就永远查不出来了
/// （v1.3.53 那次"大文件滚一下就死"就是靠它定位的）。
///
/// 诊断关着的时候，崩溃遗言退到 `stderr`（见 `recordCrash`）：
/// 从访达启动的 app 能在 Console.app 里看到，Xcode / 终端里跑就直接打在屏幕上 ——
/// **不落文件**，符合"关着的时候一个日志文件都不建"。
final class Diagnostics: @unchecked Sendable {

    static let shared = Diagnostics()

    // MARK: - 总开关

    /// `UserDefaults` 里的键。**`AppPreferences` 读的是同一个字符串**，别只改一边。
    static let defaultsKey = "pref.diagnosticsEnabled"

    /// 这份构建的默认值：**Debug 开、Release 关**（效率优先）。
    static var defaultEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// 当前生效的开关。热路径（`record` / `activity`）读的就是它 ——
    /// 不加锁、不碰 `UserDefaults`，一次字节读，几纳秒。
    static var isEnabled: Bool { enabledFlag }

    /// 改开关。**唯一入口** —— 顺手把常驻设施装起来 / 拆掉，立即生效。
    ///
    /// ⚠️ 只能在主线程调（`CFRunLoopAddObserver` 和 `NSEvent` 监听都要求主线程）。
    static func setEnabled(_ on: Bool) {
        guard enabledFlag != on else { return }
        if !on {
            // 这一行必须在翻开关**之前**记，否则它自己就被 `guard` 拦掉了
            shared.record("诊断已关闭 —— 之后不再写日志、不装看门狗、不监听鼠标事件")
        }
        enabledFlag = on
        UserDefaults.standard.set(on, forKey: defaultsKey)
        if on {
            shared.activate()
            shared.record("诊断已开启（设置里打开的）· 日志：\(shared.logURL.path)")
        } else {
            shared.deactivate()
        }
    }

    /// 自动化验证正在跑吗（`PDFREADER_*` 环境变量 / `--autoquit-after`）？
    ///
    /// ⚠️ 是的话**强制打开诊断** —— 不看构建配置、也不看用户偏好。
    ///
    /// 原因：`AutomationHooks` 那套钩子**全靠回读日志判结果**（"滚了 600 步还活着"
    /// "关窗口时问了没有"），日志一关就什么都验不了。而自检恰恰是用命令行
    /// `swift build -c release` 出的包跑的 —— 那正是"默认关"的那一种。
    static var automationRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        if env.keys.contains(where: { $0.hasPrefix("PDFREADER_") }) { return true }
        return CommandLine.arguments.contains("--autoquit-after")
    }

    /// 真正的开关值。
    ///
    /// `nonisolated(unsafe)` 是**故意**的：它就要能被任意线程裸读
    ///（热路径上加一次锁的代价比这个判断本身还大），而 `Bool` 的单字节读写是原子的。
    /// 初始化走 `swift_once`，本身线程安全。
    nonisolated(unsafe) private static var enabledFlag: Bool = {
        if automationRequested { return true }
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool { return stored }
        return defaultEnabled
    }()

    /// 主线程单轮超过这个时长（毫秒）记一条
    static let slowThreshold: Double = 60

    /// 主线程超过这么久**没有任何进展**就判定为卡死（秒）—— 由后台线程盯着。
    ///
    /// 定 5 秒：正常操作里主线程不会停这么久；而"用户以为死掉了"的那种卡顿
    /// 基本都在 5 秒以上。所以这条记录基本可以直接当成"用户看到的死"。
    static let hangThreshold: Double = 5

    let logURL: URL

    /// **最近一次操作**在做什么。慢轮次记录会带上它 —— 一眼看出"卡在哪一步"。
    ///
    /// ⚠️ 语义是"最近一次"，**不是"当前"**：调用方不要在操作结束时清空。
    ///
    /// 因为慢轮次是在"一轮处理结束、即将进入等待"时才被发现的 ——
    /// 那一刻操作早就做完了，如果标签已经被清成"空闲"，这条记录就毫无信息量
    /// （自检时踩到过：350ms 记到了，活动却显示"空闲"）。
    var activity: String {
        get { lock.lock(); defer { lock.unlock() }; return currentActivity }
        set {
            // 关着的时候连这个锁都不进 —— 它在"换页 / 重载目录"这类热路径上会被频繁调
            guard Self.isEnabled else { return }
            lock.lock()
            let changed = currentActivity != newValue
            currentActivity = newValue
            lock.unlock()
            // 顺手同步一份到 C 缓冲：崩溃信号 handler 里没法读 Swift 字符串
            if changed {
                newValue.withCString { _ = strlcpy(crashActivityBuffer, $0, 256) }
            }
        }
    }

    private var currentActivity = "空闲"
    private let lock = NSLock()
    /// 写日志用的锁（与 `lock` 分开：写盘时不该把 activity 读者一起堵住）
    private let writeLock = NSLock()
    private var counters: [String: Int] = [:]
    /// 日志文件的写句柄。`O_APPEND` 保证多线程追加不互相打断。
    private var fd: Int32 = -1
    private var observer: CFRunLoopObserver?
    /// 看门狗装过没有（开关可以被反复开关，装只能装一次）
    private var watchdogInstalled = false
    /// 卡死检测线程起过没有（同上：起只能起一次）
    private var hangDetectorInstalled = false
    /// 鼠标事件监听的令牌（`NSEvent.removeMonitor` 要它）
    private var mouseMonitor: Any?
    /// 会话开始时间，用来给慢轮次标"启动后第几秒"
    private var sessionStart = Date()

    /// 主线程"**正在干活**"的起点；空闲（在等事件）时是 nil。
    ///
    /// ⚠️ 这里踩过一个坑（自检当场抓到）：一开始用的是"心跳时刻"——
    /// 主线程每轮 runloop 都拍一下，超过 5 秒没拍就报卡死。
    /// 结果**空闲也被当成卡死**：主线程没事件时就阻塞在 `nextEventMatchingMask` 里等，
    /// runloop observer 根本不触发，心跳自然不更新 —— 日志里出现了
    /// "主线程卡死 6 秒"接着"主线程恢复"，而那一刻 app 只是开着窗口没人操作。
    ///
    /// 所以改成区分"忙/闲"：
    /// - `afterWaiting`（被唤醒、开始处理事件）→ 记下起点，进入"忙"；
    /// - `beforeWaiting`（活干完、准备睡）→ 清掉，进入"闲"。
    ///
    /// **只有"忙"才计时** —— 空闲等多久都不算卡死，这才对得上"用户看到的死"。
    private var busySince: CFAbsoluteTime? = CFAbsoluteTimeGetCurrent()
    private var busyLock = NSLock()
    /// 这一轮卡死已经报过了吗（避免每秒刷屏）
    private var hangReported = false
    private var hangPeak: Double = 0

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        // ⚠️ 这里**只拼路径，不碰文件系统** —— 诊断默认可能是关的（Release），
        // 关着的时候连日志目录都不该被建出来。真正要写的时候由 `activate()` 一次性备好。
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        logURL = base.appendingPathComponent("PDFReader", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
        // 初始活动也抄一份进 C 缓冲：否则"启动阶段就崩"时那一栏是空的
        _ = strlcpy(crashActivityBuffer, "空闲（还在启动阶段）", 256)
        // 崩溃兜底**不看开关**（理由见类注释）—— 平时零开销，只在要死的那一刻动一下
        installCrashSignalHandlers()
    }

    // MARK: - 常驻设施的装 / 拆（开关打开时才做）

    /// 把开关打开后需要的东西一次性备好。幂等 —— 重复调没有代价。
    ///
    /// ⚠️ 主线程专用：`CFRunLoopAddObserver` 和 `NSEvent.addLocalMonitorForEvents`
    /// 都要求主线程。
    private func activate() {
        writeLock.lock()
        openLogLocked()
        writeLock.unlock()
        installMainThreadWatchdog()
        installHangDetector()
        installMouseMonitor()
    }

    /// 拆掉常驻设施。
    ///
    /// **日志句柄留着不关**：下次打开接着往里写，不用重开，也不会丢历史记录。
    private func deactivate() {
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        watchdogInstalled = false
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        // 卡死检测线程**不杀**：它在循环里自己看 `isEnabled`，关着就只是每秒空醒一下，
        // 代价可以忽略；真要"杀掉"得能中断 `Thread.sleep`，不值得为这点开销加复杂度。
    }

    /// 建目录 → 轮转 → 开句柄。**调用方必须已经持有 `writeLock`。**
    ///
    /// 句柄用 `O_APPEND`：多线程追加不会互相咬断（配合 `writeLock` 双保险）。
    private func openLogLocked() {
        guard fd < 0 else { return }
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rotateIfNeeded()
        fd = logURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) } ?? -1
        }
        // 崩溃信号 handler 只能用这个 fd（碰不到实例）—— 开了就同步过去
        crashLogFD = fd
    }

    // MARK: - 写日志（同步直写）

    /// 记一条。**同步落盘** —— 进程被强杀也不丢。诊断关着时直接返回，一个字都不写。
    ///
    /// ⚠️ 原来是"异步扔给后台队列 + `FileHandle` 写"，看着优雅，实际在最需要日志的
    /// 场景（app 卡死、用户强制退出）**内容全丢**：用户那次"滚动就死"的日志里，
    /// 连一行都没留下。改成直接 `write(2)` 之后，任何线程、任何时刻写下的行都在盘上。
    ///
    /// 开销：一次 `write` 系统调用（微秒级）。日志本来就没几条，不值得为它做缓冲。
    ///
    /// ## `@autoclosure` 不是装饰（v1.3.68）
    ///
    /// 参数是**惰性**的：诊断关着时，**连这句话都不拼** —— 所有调用点自动省掉。
    ///
    /// 这不是理论收益。`PDFViewModel.markDirty()` 里那句
    /// `record("标脏 ← …" + Thread.callStackSymbols…)` 会去**走一遍调用栈并符号化**
    /// （几十微秒到毫秒级），而它是在**每一次文档改动**时都调的。以前它作为实参
    /// 先算好再传进来 —— 关不关诊断都照算不误。加了 `@autoclosure` 之后，
    /// 关着就真的一个字节都不拼、一次栈都不走。
    func record(_ message: @autoclosure () -> String) {
        guard Self.isEnabled else { return }
        let line = "[\(Self.stamp.string(from: Date()))] \(message())\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        // 启动极早期就有人调 `record`（比如 `App.init()` 里那条）—— 那时还没 startSession，
        // 句柄没开，就地补开。已经开着的话这里只是一次 `fd < 0` 的判断。
        openLogLocked()
        writeLocked(line)
    }

    /// 崩溃遗言专用：**不受总开关影响**（理由见类注释）。
    ///
    /// 诊断关着的时候句柄是 -1，这些行退到 `stderr` ——
    /// 从访达启动的 app 能在 Console.app 里看到，Xcode / 终端里跑就直接打在屏幕上。
    /// 代价只有"崩溃那一刻的几次 write"，换来的是"用户报崩溃时一定有证据"。
    func recordCrash(_ message: String) {
        let line = "[\(Self.stamp.string(from: Date()))] \(message)\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        writeLocked(line, fallbackToStderr: true)
    }

    /// 真正落盘的那一下。加锁 + `O_APPEND` 保证多线程写出来的行不互相咬。
    ///
    /// **调用方必须已经持有 `writeLock`。**
    ///
    /// - Parameter fallbackToStderr: 句柄没开时要不要退到 `stderr`。
    ///   正常日志传 false（关着就不该有任何输出），崩溃遗言传 true。
    private func writeLocked(_ text: String, fallbackToStderr: Bool = false) {
        let target = fd >= 0 ? fd : (fallbackToStderr ? STDERR_FILENO : -1)
        guard target >= 0 else { return }
        text.withCString { pointer in
            var offset = 0
            let total = strlen(pointer)
            while offset < total {
                let written = Darwin.write(target, pointer + offset, total - offset)
                if written <= 0 { break }   // 写不进去（磁盘满 / 已被关闭）就算了，别死循环
                offset += written
            }
        }
    }

    /// 兼容老调用点：同步写之后已经没有"挂起的写入"了，留个空实现。
    func flush() {}

    // MARK: - 崩溃信号兜底（v1.3.53）

    /// 给几个致命信号挂 handler：**在进程死掉之前，把当前线程的调用栈砸进日志**。
    ///
    /// ## 为什么不是 `NSSetUncaughtExceptionHandler`
    ///
    /// 那个对 Objective-C 异常有效，但只在 `NSApplicationMain` 那层 `@try` 里被调用。
    /// 用户机器上那次崩溃走的是另一条路（系统崩溃报告原样）：
    ///
    /// ```
    /// objc_exception_throw → __cxa_throw → std::__terminate → abort → SIGABRT
    /// ```
    ///
    /// 也就是"异常一路没人接，最后直接 abort" —— 这条路**根本不会调用 uncaught handler**，
    /// 所以日志里一条遗言都没有。信号 handler 才是这条路上唯一的落点。
    ///
    /// ## handler 里只准做 async-signal-safe 的事
    ///
    /// 只能：`write` / `strlcpy` / `backtrace` / `backtrace_symbols_fd`。
    /// 不能：分配内存、加锁、碰 Objective-C 对象、调 Swift 会分配的方法。
    /// 所以那句"最近活动"是主线程**提前**抄在 C 缓冲里的（见 `activity` 的 setter）。
    ///
    /// ## 处理完还要把信号交回去
    ///
    /// 恢复默认处理再 `raise` —— 系统的崩溃报告（`.ips`）和 Xcode 的调试器都还照旧工作，
    /// 我们只是"路过时先写一行"。
    private func installCrashSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signalNumber in
            let fd = crashLogFD >= 0 ? crashLogFD : STDERR_FILENO

            // 手写拼串：只用 C 函数，且**不打印数字** ——
            // `snprintf` 是变参函数，Swift 里不可用（编译期直接拒），
            // 而自己拼十进制又要用数组（堆分配，信号上下文里禁止）。
            // 干脆按信号名直接写死，顺带把"这是什么意思"标出来，看日志不用再查。
            crashLineBuffer[0] = 0
            strlcat(crashLineBuffer, "\n‼️ 进程收到致命信号 ", 1024)
            switch signalNumber {
            case SIGABRT: strlcat(crashLineBuffer, "SIGABRT（abort：未捕获异常 / 断言失败）\n", 1024)
            case SIGSEGV: strlcat(crashLineBuffer, "SIGSEGV（段错误：野指针 / 访问已释放对象）\n", 1024)
            case SIGBUS: strlcat(crashLineBuffer, "SIGBUS（总线错误：非法内存访问）\n", 1024)
            case SIGILL: strlcat(crashLineBuffer, "SIGILL（非法指令）\n", 1024)
            case SIGTRAP: strlcat(crashLineBuffer, "SIGTRAP（陷阱：Swift 运行时失败 / 溢出）\n", 1024)
            default: strlcat(crashLineBuffer, "（未知信号）\n", 1024)
            }
            strlcat(crashLineBuffer, "   最近活动：", 1024)
            strlcat(crashLineBuffer, crashActivityBuffer, 1024)
            strlcat(crashLineBuffer, "\n   下面是当前线程的调用栈（符号化靠 atos / Xcode）：\n", 1024)
            _ = Darwin.write(fd, crashLineBuffer, strlen(crashLineBuffer))

            let count = backtrace(crashFrames, 64)
            backtrace_symbols_fd(crashFrames, count, fd)

            // 交回默认处理：该死还是死，系统的崩溃报告照旧生成
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
        for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(number, handler)
        }
    }

    // MARK: - 「上次拖放结束」时刻（v1.3.34）

    /// 最近一次目录拖放**放下**的时刻。
    ///
    /// 专门用来回答"拖完之后那两秒里，鼠标事件到底有没有到达 app"：
    /// 鼠标监听会把"按下 / 抬起"连带上"距上次放下多少毫秒"一起记下来。
    /// 于是 --
    ///
    /// - 有「鼠标按下」也有「点击目录项」→ 事件到了、也被处理了；
    /// - 有「鼠标按下」但**没有**「点击目录项」→ 事件到了视图这一层却没被接住；
    /// - 连「鼠标按下」都没有 → 事件在 AppKit 那层就被吞掉了（拖拽会话没收干净）。
    private var lastDropEndedAt: Date?

    func noteDropEnded() {
        guard Self.isEnabled else { return }
        lock.lock()
        lastDropEndedAt = Date()
        lock.unlock()
    }

    /// 距上次拖放放下过了多少毫秒；从没放下过就返回 nil。
    func millisSinceDropEnded() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastDropEndedAt else { return nil }
        return Int(Date().timeIntervalSince(last) * 1000)
    }

    /// 记一条"鼠标事件"，但**只在拖放附近**才记（其余时候静默，免得刷屏）。
    ///
    /// - Parameter window: 只记录"距上次放下不超过这个毫秒数"的事件。默认 6 秒。
    func recordMouse(_ kind: String, within window: Int = 6000) {
        guard Self.isEnabled else { return }
        guard let gap = millisSinceDropEnded(), gap <= window else { return }
        record(String(format: "鼠标%@ · 距上次放下 %d ms", kind, gap))
    }

    /// 量一段代码的耗时，超过阈值就记一条（用来抓"这一步到底慢在哪"）。
    ///
    /// 比笼统的 `activity` 标签准 —— `activity` 语义是"最近一次做了什么"，
    /// 慢轮次记到它的时候往往已经过去了，误导过好几轮排查（v1.3.32 那次的"重载目录列表"）。
    @discardableResult
    func measure<T>(_ label: String, threshold: Double = 40, _ body: () throws -> T) rethrows -> T {
        // 关着的时候连两次 `Date()` 都省掉，直接跑原逻辑
        guard Self.isEnabled else { return try body() }
        let started = Date()
        let result = try body()
        let ms = Date().timeIntervalSince(started) * 1000
        if ms >= threshold {
            record(String(format: "耗时 %6.0f ms · %@", ms, label))
        }
        return result
    }

    // MARK: - 计数（用于"被调用了多少次"这类信息）

    func count(_ key: String, by amount: Int = 1) {
        guard Self.isEnabled else { return }
        lock.lock()
        counters[key, default: 0] += amount
        lock.unlock()
    }

    /// 把累计的计数写一条日志并清零（只在慢轮次或关键节点调用）
    func flushCounters(_ note: String = "") {
        guard Self.isEnabled else { return }
        lock.lock()
        let snapshot = counters
        counters.removeAll()
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let text = snapshot.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
        record("  计数\(note.isEmpty ? "" : "（\(note)）")：\(text)")
    }

    // MARK: - 会话

    /// 开一次会话。
    ///
    /// ⚠️ `version` 是 `@autoclosure`：调用点那句
    /// `"\(AppInfo.version) · 构建 \(AppInfo.buildStamp)"` 里，
    /// `buildStamp` 要去 **stat 可执行文件**取构建时刻 —— 关着诊断时不该为它白跑一次
    /// 文件系统调用。惰性之后，关着就真的不算。
    func startSession(version: @autoclosure () -> String) {
        sessionStart = Date()
        // ⚠️ 开关关着（Release 默认）就直接返回：日志文件不建、看门狗不装、检测线程不起。
        // 崩溃兜底不受影响 —— 它在 `init` 里就装好了（理由见类注释）。
        guard Self.isEnabled else { return }
        activate()
        let versionText = version()
        record("")
        record("════════ 启动 \(versionText) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ════════")
        record("  日志：\(logURL.path)")
    }

    /// 主线程看门狗：每一轮"真正干活"的时间超过阈值就记一条。
    ///
    /// ⚠️ 量的是 `afterWaiting → beforeWaiting` 之间，**不含空闲等待** ——
    /// 用"两次 beforeWaiting 的间隔"会把 Timer 的空闲等待也算进去，
    /// 看着像"每轮都卡 300ms"，其实是"等事件等了 300ms"（这个坑踩过）。
    ///
    /// ⚠️ 这个 observer **每一轮 runloop 都会被调一次**，是这套诊断里唯一"一直在花时间"
    /// 的东西 —— 所以它归总开关管：关着的时候压根不装。
    private func installMainThreadWatchdog() {
        guard !watchdogInstalled else { return }
        watchdogInstalled = true
        var wake = CFAbsoluteTimeGetCurrent()
        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        let newObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if activity.contains(.afterWaiting) {
                // 被唤醒 → 开始干活，从这里起算"忙了多久"
                self.busyLock.lock()
                self.busySince = now
                self.busyLock.unlock()
                wake = now
            } else if activity.contains(.beforeWaiting) {
                // 活干完、要睡了 → 不再计时（空闲等多久都不算卡死）
                self.busyLock.lock()
                self.busySince = nil
                self.busyLock.unlock()
                let ms = (now - wake) * 1000
                wake = now
                guard ms > Diagnostics.slowThreshold else { return }
                let elapsed = Date().timeIntervalSince(sessionStart)
                record(String(format: "慢轮次 %7.0f ms · 启动后 %.1fs · 活动=%@",
                              ms, elapsed, activity0(self)))
                flushCounters("卡顿前累计")
            }
        }
        observer = newObserver
        CFRunLoopAddObserver(CFRunLoopGetMain(), newObserver, .commonModes)
        record("主线程看门狗已装（阈值 \(Int(Self.slowThreshold))ms）")
    }

    // MARK: - 卡死检测（后台线程，v1.3.53）

    /// 后台线程：每秒看一次"主线程还在干活吗"。
    ///
    /// ## 为什么必须另起线程
    ///
    /// 用户那份日志里最刺眼的一件事：**打开文件之后什么都没有** ——
    /// 没有慢轮次、没有下一页、没有关闭记录，就断了。因为所有记录都发生在主线程，
    /// 而主线程恰好就是卡住的那一个。看门狗自己在主线程上，等于"事故现场没人写报告"。
    ///
    /// 现在这个线程活着，主线程卡死时它会**每秒看一眼、写一条**：
    /// 卡了多久、卡住的瞬间在干什么。用户下次再说"死"，日志里就有确凿的时间线。
    ///
    /// ⚠️ 判据是"`afterWaiting` 之后迟迟没有 `beforeWaiting`"（见 `busySince`），
    /// **不是**"主线程没动静" —— 后者会把"开着窗口没人操作"也报成卡死。
    ///
    /// ⚠️ 这个线程**每秒醒一次**，是常驻开销 —— 归总开关管：关着的时候压根不起。
    private func installHangDetector() {
        guard hangDetectorInstalled == false else { return }
        hangDetectorInstalled = true
        let thread = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let self else { return }
                // 开关被关掉之后就只是每秒空醒一下，不再干活（线程本身不杀，见 `deactivate`）
                guard Self.isEnabled else { continue }
                self.busyLock.lock()
                let since = self.busySince
                self.busyLock.unlock()
                guard let since else {
                    if self.hangReported {
                        self.record(String(format: "✅ 主线程恢复（刚才最多卡了 %.1f 秒）", self.hangPeak))
                        self.hangReported = false
                        self.hangPeak = 0
                    }
                    continue
                }
                let stuck = CFAbsoluteTimeGetCurrent() - since
                guard stuck >= Self.hangThreshold else { continue }
                let elapsed = Date().timeIntervalSince(self.sessionStart)
                if !self.hangReported {
                    self.hangReported = true
                    self.hangPeak = stuck
                    self.record(String(format: "⛔️ 主线程卡死：已 %.1f 秒没有任何进展"
                                       + "（启动后 %.1fs · 最近活动=%@）"
                                       + " —— 这一行是后台线程写的，主线程此刻动不了",
                                       stuck, elapsed, self.activity))
                } else if stuck > self.hangPeak {
                    self.hangPeak = stuck
                    // 每多卡 5 秒复述一次，方便看出"到底卡了多久才回来"
                    if Int(stuck) % 5 == 0 {
                        self.record(String(format: "⛔️ 主线程仍卡死中：已 %.1f 秒（最近活动=%@）",
                                           stuck, self.activity))
                    }
                }
            }
        }
        thread.name = "com.jiejie.pdfreader.hang-detector"
        thread.stackSize = 64 * 1024
        thread.start()
    }

    // MARK: - 鼠标事件监听（v1.3.34，v1.3.68 从 AppDelegate 搬进来）

    /// 记下"鼠标按下 / 抬起"，但 `recordMouse` 会把"离上次拖放太远"的事件丢掉 ——
    /// 不拖目录的时候，这个监听一条日志都不产生。
    ///
    /// 只盯按下 / 抬起两种，**不盯** `leftMouseDragged`（那会每秒几十条）。
    ///
    /// 目的单一：回答"拖完之后那两秒里，鼠标事件到底有没有到达 app"（见 `recordMouse`）。
    ///
    /// ⚠️ 它挂在**每一次点击**的回调上，是常驻开销 —— 归总开关管。
    /// 搬进 `Diagnostics`（原来在 `AppDelegate`）就是为了让开关能在运行时把它装上/拆掉。
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            Diagnostics.shared.recordMouse(event.type == .leftMouseDown ? "按下" : "抬起")
            return event
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
           size > 512 * 1024 {
            let old = logURL.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logURL, to: old)
        }
    }
}

/// 小工具：闭包里读 activity（`[weak self]` 下不能直接用属性，单独抽出来避免歧义）
private func activity0(_ d: Diagnostics) -> String { d.activity }
