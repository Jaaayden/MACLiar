import Darwin
import Foundation

/// The persistence boundary used by the privileged daemon.
///
/// The store deliberately knows nothing about policy semantics.  That keeps it
/// usable with the versioned `ConfigurationDocument` in Shared as well as with
/// fixtures supplied by unit tests.  The document itself owns policy defaults,
/// pending work and history retention; this type owns the on-disk envelope,
/// permissions and replacement semantics.
public protocol ConfigurationStoring {
  func load<T: Decodable>(_ type: T.Type) throws -> T
  func save<T: Encodable>(_ configuration: T) throws
}

public enum ConfigurationStoreError: Error, LocalizedError, Equatable {
  case missingConfiguration(URL)
  case unsupportedSchemaVersion(expected: Int, actual: Int)
  case malformedConfiguration(URL)
  case insecureDirectory(URL)
  case insecureConfigurationFile(URL)
  case fileSystem(operation: String, code: Int32)

  public var errorDescription: String? {
    switch self {
    case let .missingConfiguration(url):
      return "Configuration does not exist at \(url.path)."
    case let .unsupportedSchemaVersion(expected, actual):
      return "Configuration schema \(actual) is unsupported; expected \(expected)."
    case let .malformedConfiguration(url):
      return "Configuration at \(url.path) is not valid JSON for this schema."
    case let .insecureDirectory(url):
      return "Configuration directory \(url.path) is not a private directory."
    case let .insecureConfigurationFile(url):
      return "Configuration file \(url.path) is not a private regular file."
    case let .fileSystem(operation, code):
      return "\(operation) failed: \(String(cString: strerror(code)))."
    }
  }
}

/// Writes a versioned JSON configuration into a root-only directory.
///
/// Initialisation is intentionally inert: neither the directory nor the file
/// is created until `save` is called.  Tests can inject a temporary `fileURL`
/// and never need access to the production path.
public final class ConfigurationStore: ConfigurationStoring {
  public static let defaultDirectoryURL = URL(
    fileURLWithPath: "/Library/Application Support/local.macdancer.MACDancer",
    isDirectory: true
  )

  public static let defaultFileURL = defaultDirectoryURL
    .appendingPathComponent("configuration.json", isDirectory: false)

  public let fileURL: URL
  public let schemaVersion: Int

  private let fileManager: FileManager
  /// Root ownership is required for the production path.  An injected test URL
  /// is intentionally allowed to be owned by the unprivileged test runner.
  private let requiresRootOwnership: Bool

  public init(
    fileURL: URL = ConfigurationStore.defaultFileURL,
    schemaVersion: Int = 1,
    fileManager: FileManager = .default
  ) {
    precondition(schemaVersion > 0, "A configuration schema version must be positive.")
    self.fileURL = fileURL.standardizedFileURL
    self.schemaVersion = schemaVersion
    self.fileManager = fileManager
    requiresRootOwnership = self.fileURL.path.hasPrefix(
      Self.defaultDirectoryURL.standardizedFileURL.path + "/"
    )
  }

  public func load<T: Decodable>(_ type: T.Type) throws -> T {
    try validateConfigurationFileForReading()

    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    } catch {
      throw fileSystemError("read configuration")
    }

    do {
      let envelope = try JSONDecoder().decode(DecodingEnvelope<T>.self, from: data)
      guard envelope.schemaVersion == schemaVersion else {
        throw ConfigurationStoreError.unsupportedSchemaVersion(
          expected: schemaVersion,
          actual: envelope.schemaVersion
        )
      }
      return envelope.configuration
    } catch let error as ConfigurationStoreError {
      throw error
    } catch {
      throw ConfigurationStoreError.malformedConfiguration(fileURL)
    }
  }

  /// Loads the daemon document, returning a safe in-memory default on first run.
  ///
  /// This intentionally does not create a file.  Construction and read paths
  /// must never mutate `/Library`; the first explicit save establishes the
  /// private directory and configuration file.
  func loadOrCreateDocument() throws -> ConfigurationDocument {
    do {
      return try load(ConfigurationDocument.self)
    } catch ConfigurationStoreError.missingConfiguration {
      return ConfigurationDocument()
    }
  }

  public func save<T: Encodable>(_ configuration: T) throws {
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      data = try encoder.encode(EncodingEnvelope(schemaVersion: schemaVersion, configuration: configuration))
    } catch {
      throw ConfigurationStoreError.malformedConfiguration(fileURL)
    }

    try ensurePrivateConfigurationDirectory()
    try validateExistingConfigurationFileForReplacement()
    try replaceAtomically(with: data)
  }

  // MARK: - Private

  private struct DecodingEnvelope<Configuration: Decodable>: Decodable {
    let schemaVersion: Int
    let configuration: Configuration
  }

  private struct EncodingEnvelope<Configuration: Encodable>: Encodable {
    let schemaVersion: Int
    let configuration: Configuration
  }

  private var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  private func ensurePrivateConfigurationDirectory() throws {
    var status = stat()
    let result = lstat(directoryURL.path, &status)

    if result == 0 {
      guard isDirectory(status), !isSymbolicLink(status) else {
        throw ConfigurationStoreError.insecureDirectory(directoryURL)
      }
    } else if errno == ENOENT {
      do {
        try fileManager.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw fileSystemError("create configuration directory")
      }
    } else {
      throw fileSystemError("inspect configuration directory")
    }

    guard chmod(directoryURL.path, 0o700) == 0 else {
      throw fileSystemError("set configuration directory permissions")
    }

    var verified = stat()
    guard lstat(directoryURL.path, &verified) == 0,
          isDirectory(verified),
          !isSymbolicLink(verified),
          isExpectedOwner(verified),
          permissions(of: verified) == 0o700 else {
      throw ConfigurationStoreError.insecureDirectory(directoryURL)
    }
  }

  private func validateConfigurationFileForReading() throws {
    var status = stat()
    let result = lstat(fileURL.path, &status)
    if result != 0 {
      if errno == ENOENT {
        throw ConfigurationStoreError.missingConfiguration(fileURL)
      }
      throw fileSystemError("inspect configuration")
    }

    guard isRegularFile(status),
          !isSymbolicLink(status),
          isExpectedOwner(status),
          permissions(of: status) == 0o600 else {
      throw ConfigurationStoreError.insecureConfigurationFile(fileURL)
    }
  }

  private func validateExistingConfigurationFileForReplacement() throws {
    var status = stat()
    let result = lstat(fileURL.path, &status)
    if result != 0 {
      if errno == ENOENT { return }
      throw fileSystemError("inspect existing configuration")
    }

    guard isRegularFile(status), !isSymbolicLink(status), isExpectedOwner(status) else {
      throw ConfigurationStoreError.insecureConfigurationFile(fileURL)
    }
  }

  private func replaceAtomically(with data: Data) throws {
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    var hasCommitted = false
    defer {
      if !hasCommitted {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    guard fileManager.createFile(
      atPath: temporaryURL.path,
      contents: nil,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw fileSystemError("create temporary configuration")
    }

    do {
      let handle = try FileHandle(forWritingTo: temporaryURL)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      throw fileSystemError("write temporary configuration")
    }

    guard chmod(temporaryURL.path, 0o600) == 0 else {
      throw fileSystemError("set temporary configuration permissions")
    }

    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      throw fileSystemError("atomically replace configuration")
    }
    hasCommitted = true

    let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directoryDescriptor >= 0 else {
      throw fileSystemError("open configuration directory for synchronization")
    }
    defer { close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else {
      throw fileSystemError("synchronize configuration directory")
    }

    var status = stat()
    guard lstat(fileURL.path, &status) == 0,
          isRegularFile(status),
          !isSymbolicLink(status),
          isExpectedOwner(status),
          permissions(of: status) == 0o600 else {
      throw ConfigurationStoreError.insecureConfigurationFile(fileURL)
    }
  }

  private func isDirectory(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
  }

  private func isRegularFile(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
  }

  private func isSymbolicLink(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
  }

  private func permissions(of status: stat) -> mode_t {
    status.st_mode & 0o777
  }

  private func isExpectedOwner(_ status: stat) -> Bool {
    !requiresRootOwnership || status.st_uid == 0
  }

  private func fileSystemError(_ operation: String) -> ConfigurationStoreError {
    ConfigurationStoreError.fileSystem(operation: operation, code: errno)
  }
}
