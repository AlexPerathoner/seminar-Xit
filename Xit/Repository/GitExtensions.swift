import Foundation


extension git_fetch_options
{
  public static func withOptions<T>(_ fetchOptions: FetchOptions,
                                    action: (git_fetch_options) throws -> T)
    rethrows -> T
  {
    var options = git_fetch_options.defaultOptions()
    
    options.prune = fetchOptions.pruneBranches ?
        GIT_FETCH_PRUNE : GIT_FETCH_NO_PRUNE
    options.download_tags = fetchOptions.downloadTags ?
        GIT_REMOTE_DOWNLOAD_TAGS_ALL : GIT_REMOTE_DOWNLOAD_TAGS_AUTO
    return try git_remote_callbacks.withCallbacks(fetchOptions.callbacks) {
      (callbacks) in
      options.callbacks = callbacks
      return try action(options)
    }
  }
}

extension git_index_entry
{
  /// The stage value is stored in certain bits of the `flags` field.
  var stage: UInt16
  {
    get
    {
      (flags & UInt16(GIT_INDEX_ENTRY_STAGEMASK)) >> GIT_INDEX_ENTRY_STAGESHIFT
    }
    set
    {
      let cleared = flags & ~UInt16(GIT_INDEX_ENTRY_STAGEMASK)
      
      flags = cleared | ((newValue & 0x03) << UInt16(GIT_INDEX_ENTRY_STAGESHIFT))
    }
  }
}

fileprivate extension RemoteCallbacks
{
  static func fromPayload(_ payload: UnsafeMutableRawPointer?)
    -> UnsafeMutablePointer<RemoteCallbacks>?
  {
    return payload?.bindMemory(to: RemoteCallbacks.self, capacity: 1)
  }
}

extension git_remote_callbacks
{
  private enum Callbacks
  {
    private static func sshKeyPaths() -> [String]
    {
      let manager = FileManager.default
      let sshDirectory = manager.homeDirectoryForCurrentUser
                                .appendingPathComponent(".ssh")
      var result: [String] = []
      guard let enumerator = manager.enumerator(at: sshDirectory,
                                                includingPropertiesForKeys: nil)
      else { return result }
      let suffixes = ["_rsa", "_dsa", "_ecdsa", "_ed25519"]
      
      enumerator.skipDescendants()
      while let url = enumerator.nextObject() as? URL {
        let name = url.lastPathComponent
        guard suffixes.contains(where: { name.hasSuffix($0) }),
              manager.fileExists(atPath: url.appendingPathExtension("pub").path)
        else { continue }
        
        result.append(url.path)
      }
      
      return result
    }
    
    static let credentials: git_cred_acquire_cb = {
      (cred, urlCString, userCString, allowed, payload) in
      guard let callbacks = RemoteCallbacks.fromPayload(payload)
      else { return -1 }
      let allowed = git_credential_t(allowed)
      
      if allowed.contains(GIT_CREDENTIAL_SSH_KEY) {
        var result: Int32 = 1
        
        for path in sshKeyPaths() {
          let publicPath = path.appending(".pub")
          
          result = git_cred_ssh_key_new(cred, userCString, publicPath, path, "")
          if result == 0 {
            break
          }
          else {
            let error = RepoError(gitCode: git_error_code(rawValue: result))
            
            repoLogger.debug("Could not load ssh key for \(path): \(error))")
          }
        }
        if result == 0 {
          return 0
        }
      }
      if allowed.contains(GIT_CREDENTIAL_USERPASS_PLAINTEXT) {
        let keychain = KeychainStorage.shared
        let urlString = urlCString.flatMap { String(cString: $0) }
        let urlObject = urlString.flatMap { URL(string: $0) }
        let userName = userCString.map { String(cString: $0) } ??
                       urlObject?.impliedUserName
        
        if let url = urlObject,
           let user = userName,
           let password = keychain.find(url: url, account: userName) ??
                          keychain.find(url: url.withPath(""),
                                        account: userName) {
          return git_cred_userpass_plaintext_new(cred, user, password)
        }
        if let (user, password) = callbacks.pointee.passwordBlock!() {
          return git_cred_userpass_plaintext_new(cred, user, password)
        }
      }
      // The documentation says to return >0 to indicate no credentials
      // acquired, but that leads to an assertion failure.
      return -1
    }
    
    static let transferProgress: git_transfer_progress_cb = {
      (stats, payload) in
      guard let callbacks = RemoteCallbacks.fromPayload(payload),
            let progress = stats?.pointee
      else { return -1 }
      let transferProgress = GitTransferProgress(gitProgress: progress)
      
      return callbacks.pointee.downloadProgress!(transferProgress) ? 0 : -1
    }
    
    static let pushTransferProgress: git_push_transfer_progress = {
      (current, total, bytes, payload) in
      guard let callbacks = RemoteCallbacks.fromPayload(payload)
      else { return -1 }
      let progress = PushTransferProgress(current: current, total: total,
                                          bytes: bytes)
      
      return callbacks.pointee.uploadProgress!(progress) ? 0 : -1
    }
    
    static let sidebandMessage: git_transport_message_cb = {
      (cString, length, payload) in
      guard let callbacks = RemoteCallbacks.fromPayload(payload)
      else { return -1 }
      guard let cString = cString
      else { return 0 }
      let stringData = Data(bytes: cString, count: Int(length))
      guard let message = String(data: stringData, encoding: .utf8)
      else { return 0 }
      
      return callbacks.pointee.sidebandMessage!(message) ? 0 : -1
    }
  }
  
  /// Calls the given action with a populated callbacks struct.
  /// The "with" pattern is needed because of the need to make a mutable copy
  /// of the given callbacks as a payload, and perform the action within the
  /// scope of that copy.
  public static func withCallbacks<T>(_ callbacks: RemoteCallbacks,
                                      action: (git_remote_callbacks) throws -> T)
    rethrows -> T
  {
    var gitCallbacks = git_remote_callbacks.defaultOptions()
    var mutableCallbacks = callbacks
    
    return try withUnsafeMutableBytes(of: &mutableCallbacks) {
      (buffer) in
      gitCallbacks.payload = buffer.baseAddress

      if callbacks.passwordBlock != nil {
        gitCallbacks.credentials = Callbacks.credentials
      }
      if callbacks.downloadProgress != nil {
        gitCallbacks.transfer_progress = Callbacks.transferProgress
      }
      if callbacks.uploadProgress != nil {
        gitCallbacks.push_transfer_progress = Callbacks.pushTransferProgress
      }
      return try action(gitCallbacks)
    }
  }
}

extension Array where Element == String
{
  /// Converts the given array to a `git_strarray` and calls the given block.
  /// This is patterned after `withArrayOfCStrings` except that function does
  /// not produce the necessary type.
  /// - parameter block: The block called with the resulting `git_strarray`. To
  /// use this array outside the block, use `git_strarray_copy()`.
  func withGitStringArray<T>(block: (git_strarray) throws -> T) rethrows -> T
  {
    let lengths = map { $0.utf8.count + 1 }
    let offsets = [0] + scan(lengths, 0, +)
    var buffer = [Int8]()
    
    buffer.reserveCapacity(offsets.last!)
    for string in self {
      buffer.append(contentsOf: string.utf8.map { Int8($0) })
      buffer.append(0)
    }
    
    let bufferSize = buffer.count
    
    return try buffer.withUnsafeMutableBufferPointer {
      (pointer) -> T in
      let boundPointer = UnsafeMutableRawPointer(pointer.baseAddress!)
                         .bindMemory(to: Int8.self, capacity: bufferSize)
      var cStrings: [UnsafeMutablePointer<Int8>?] =
            offsets.map { boundPointer + $0 }
      
      cStrings[cStrings.count-1] = nil
      return try cStrings.withUnsafeMutableBufferPointer {
        (arrayBuffer) -> T in
        let strarray = git_strarray(strings: arrayBuffer.baseAddress,
                                    count: count)
        
        return try block(strarray)
      }
    }
  }
}

extension git_strarray: RandomAccessCollection
{
  public var startIndex: Int { 0 }
  public var endIndex: Int { count }
  
  public subscript(index: Int) -> String?
  {
    return self.strings[index].map { String(cString: $0) }
  }
}

extension Data
{
  func isBinary() -> Bool
  {
    return withUnsafeBytes {
      (data: UnsafeRawBufferPointer) -> Bool in
      git_blob_data_is_binary(data.bindMemory(to: Int8.self).baseAddress,
                              count) != 0
    }
  }
}

extension String
{
  init?(gitBufferNoCopy: git_buf)
  {
    guard let result = String(
        bytesNoCopy: gitBufferNoCopy.ptr,
        length: strnlen(gitBufferNoCopy.ptr, gitBufferNoCopy.size),
        encoding: .utf8,
        freeWhenDone: false)
    else { return nil }
    
    self = result
  }
  
  /// Creates a string with a copy of the buffer's contents.
  init?(gitBuffer: git_buf)
  {
    guard let target = String(gitBufferNoCopy: gitBuffer)
    else { return nil }
    
    // Make a copy because target points to the buffer
    self = String(target)
  }
  
  /// Calls `action` with a string pointing to the given buffer. If the string
  /// could not be constructed then `nil` is passed.
  static func withGitBuffer<T>(_ buffer: git_buf,
                               action: (String?) throws -> T) rethrows -> T
  {
    let string = String(gitBufferNoCopy: buffer)
    
    return try action(string)
  }
  
  /// Normalizes whitespace and optionally strips comment lines.
  func prettifiedMessage(stripComments: Bool) -> String
  {
    let commentCharASCII = Int8(Character("#").asciiValue!)
    let gitBuffer = GitBuffer(size: 0)
    let result = git_message_prettify(&gitBuffer.buffer, self,
                                      stripComments ? 1 : 0, commentCharASCII)
    guard result == 0
    else { return self }
    
    return String(gitBuffer: gitBuffer.buffer) ?? self
  }
}

protocol CallbackInitializable
{
  /// Initializes an instance with a callback that may instead return
  /// an error code.
  /// - parameter callback: Either initializes the given pointer or returns
  /// a libgit2 error code.
  static func from(_ callback: (inout Self?) -> Int32) throws -> Self
}

extension CallbackInitializable
{
  static func from(_ callback: (inout Self?) -> Int32) throws -> Self
  {
    var pointer: Self?
    let result = callback(&pointer)
    guard result >= 0,
          let finalPointer = pointer
    else {
      throw RepoError(gitCode: git_error_code(result))
    }
    
    return finalPointer
  }
}

extension UnsafePointer: CallbackInitializable {}
extension UnsafeMutablePointer: CallbackInitializable {}
extension OpaquePointer: CallbackInitializable {}
