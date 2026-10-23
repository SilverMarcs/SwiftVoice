import Foundation

final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let completed: Int64
    let total: Int64
    let report: @Sendable (Double) -> Void

    init(completed: Int64, total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.completed = completed
        self.total = total
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(min(1, Double(completed + totalBytesWritten) / Double(max(1, total))))
    }
}
