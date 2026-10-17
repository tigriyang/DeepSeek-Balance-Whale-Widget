import Foundation

/// 单实例守卫。
///
/// 为什么必须要：首次运行会写 launchd 配置并 launchctl load -w，
/// 而配置里 RunAtLoad=true —— 于是刚启动的这个进程会在同一时刻
/// 被 launchd 又拉起来一份。结果就是两只鲸鱼完全重叠（肉眼看不出来），
/// 通知还会重复推送。
///
/// 用文件锁而不是 NSRunningApplication 查询：后者依赖 bundle id，
/// 而经 LaunchServices 启动时进程拿到的可能是临时标识，查不到。
enum SingleInstance {
    /// 持有 fd 才不会释放锁（close 即解锁）。只由主线程写入。
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    static func acquire() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/.whalefloat.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        // 连锁文件都开不了时不要拦 —— 宁可多开一份，也别让用户完全起不来
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }
}
