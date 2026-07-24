import CoreMotion
import Foundation

/// Records gyro + accelerometer data in Gyroflow's GCSV format.
///
/// GCSV format (from Gyroflow docs):
///   # gyroflow
///   # version 1.3
///   # id      name    sample_rate     rank    data_type       channel_count   channel_labels
///   GYRO      1       Gyroscope       400.00  1       2       3       x,y,z
///   ACCL      2       Accelerometer   400.00  1       2       3       x,y,z
///   # timescale section
///   # frame_rate 29.97
///   # video_size 1920 1080
///   # id_section_offset 0
///   # camera_identifier iPhone
///   # camera_matrix ... (per-frame distortion, optional)
///   ts        gx      gy      gz      ax      ay      az
///   0.000000  0.0012  0.0003  -0.0021 0.01    0.02    9.81
///   ...
public final class GyroflowRecorder: ObservableObject {

    private let motionManager = CMMotionManager()
    private let writerQueue = DispatchQueue(label: "com.logcampro.gyro", qos: .utility)
    @Published public private(set) var isRecording = false
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var startTime: TimeInterval = 0
    private var sampleRate: Double = 100  // Hz
    private var frameRate: Float = 24
    private var resolution: CGSize = CGSize(width: 1920, height: 1080)

    public init() {
        configureMotion()
    }

    private func configureMotion() {
        motionManager.gyroUpdateInterval = 1.0 / sampleRate
        motionManager.accelerometerUpdateInterval = 1.0 / sampleRate
        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRate
    }

    public func startRecording() {
        guard !isRecording else { return }
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gyro_\(ISO8601DateFormatter().string(from: Date()))")
                .appendingPathExtension("csv")
            self.fileURL = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.fileHandle = try? FileHandle(forWritingTo: url)
            self.writeHeader()
            self.startTime = CFAbsoluteTimeGetCurrent()
            self.startMotionUpdates()
            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    public func stopRecording(completion: @escaping (URL?) -> Void) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            self.motionManager.stopGyroUpdates()
            self.motionManager.stopAccelerometerUpdates()
            self.motionManager.stopDeviceMotionUpdates()
            try? self.fileHandle?.close()
            let url = self.fileURL
            DispatchQueue.main.async {
                self.isRecording = false
                completion(url)
            }
        }
    }

    public func setFrameRate(_ fps: Float) { frameRate = fps }
    public func setResolution(_ size: CGSize) { resolution = size }

    // MARK: - Motion updates

    private func startMotionUpdates() {
        motionManager.startGyroUpdates(to: OperationQueue.main) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            self.writeGyroSample(data.rotationRate)
        }
        motionManager.startAccelerometerUpdates(to: OperationQueue.main) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            self.writeAccelSample(data.acceleration)
        }
    }

    private func writeGyroSample(_ rate: CMRotationRate) {
        let t = CFAbsoluteTimeGetCurrent() - startTime
        let line = String(format: "%.6f\t%.6f\t%.6f\t%.6f\t\n",
                          t, rate.x, rate.y, rate.z)
        append(line)
    }

    private func writeAccelSample(_ acc: CMAcceleration) {
        let t = CFAbsoluteTimeGetCurrent() - startTime
        // GCSV interleaves accel columns with gyro (3 columns of accel after 3 of gyro)
        // For simplicity we write them in separate rows tagged by ACCL.
        let line = String(format: "%.6f\t\t\t\t%.6f\t%.6f\t%.6f\n",
                          t, acc.x, acc.y, acc.z)
        append(line)
    }

    private func append(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private func writeHeader() {
        var header = ""
        header += "# gyroflow\n"
        header += "# version 1.3\n"
        header += "# id_section_offset 0\n"
        header += "# camera_identifier iPhone\n"
        header += String(format: "# frame_rate %.2f\n", frameRate)
        header += String(format: "# video_size %d %d\n", Int(resolution.width), Int(resolution.height))
        header += String(format: "# imu_orientation 0 1 2\n")  // ZYX axis order, iPhone default
        header += "#\tname\tsample_rate\trank\tdata_type\tchannel_count\tchannel_labels\n"
        header += String(format: "GYRO\t1\tGyroscope\t%.2f\t1\t2\t3\tx,y,z\n", sampleRate)
        header += String(format: "ACCL\t2\tAccelerometer\t%.2f\t1\t2\t3\tx,y,z\n", sampleRate)
        header += "ts\tgx\tgy\tgz\tax\tay\taz\n"
        append(header)
    }
}
