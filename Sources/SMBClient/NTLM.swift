import Foundation
import CommonCrypto

public enum NTLM {
  public struct NegotiateMessage {
    public let signature: UInt64
    public let messageType: UInt32
    public let negotiateFlags: NegotiateFlags
    public let domainName: Fields
    public let workstationName: Fields
    public let version: UInt64

    public init(
      negotiateFlags: NegotiateFlags = [
        .negotiate56,
        .negotiateKeyExchange,
        .negotiate128,
        .negotiateVersion,
        .negotiateTargetInfo,
        .negotiateExtendedSecurity,
        .negotiateTargetTypeServer,
        .negotiateAlwaysSign,
        .negotiateNetware,
        .negotiateSeal,
        .negotiateSign,
        .requestTarget,
        .unicode,
      ],
      domainName: String? = nil,
      workstationName: String? = nil
    ) {
      signature = 0x4e544c4d53535000
      messageType = 0x00000001
      self.negotiateFlags = negotiateFlags
      let offset: UInt32 = 64
      self.domainName = Fields(value: domainName, offset: offset)
      self.workstationName = Fields(value: workstationName, offset: offset + UInt32(self.domainName.len))
      version = 0x0000000000000000
    }

    public func encoded() -> Data {
      var data = Data()
      data += signature.bigEndian
      data += messageType
      data += negotiateFlags.rawValue
      data += domainName.len
      data += domainName.maxLen
      data += domainName.bufferOffset
      data += workstationName.len
      data += workstationName.maxLen
      data += workstationName.bufferOffset
      data += version
      data += domainName.encoded() + workstationName.encoded()
      return data
    }
  }

  public struct ChallengeMessage {
    public let signature: UInt64
    public let messageType: UInt32
    public let targetNameLen: UInt16
    public let targetNameMaxLen: UInt16
    public let targetNameBufferOffset: UInt32
    public let negotiateFlags: NegotiateFlags
    public let serverChallenge: UInt64
    public let reserved: UInt64
    public let targetInfoLen: UInt16
    public let targetInfoMaxLen: UInt16
    public let targetInfoBufferOffset: UInt32
    public let version: UInt64
    public let targetName: Data
    public let targetInfo: Data

    public init(data: Data) {
      let reader = ByteReader(data)
      signature = reader.read()
      messageType = reader.read()
      targetNameLen = reader.read()
      targetNameMaxLen = reader.read()
      targetNameBufferOffset = reader.read()
      negotiateFlags = NegotiateFlags(rawValue: reader.read())
      serverChallenge = reader.read()
      reserved = reader.read()
      targetInfoLen = reader.read()
      targetInfoMaxLen = reader.read()
      targetInfoBufferOffset = reader.read()
      version = reader.read()
      targetName = reader.read(from: Int(targetNameBufferOffset), count: Int(targetNameLen))
      targetInfo = reader.read(from: Int(targetInfoBufferOffset), count: Int(targetInfoLen))
    }

    func ntowfv2(
      username: String,
      password: String,
      domain: String
    ) -> Data {
      let passwordData = password.data(using: .utf16LittleEndian)!
      var passwordHash = [UInt8](repeating: 0, count: Int(CC_MD4_DIGEST_LENGTH))
      _ = passwordData.withUnsafeBytes { (bytes) in
        CC_MD4(bytes.baseAddress, CC_LONG(passwordData.count), &passwordHash)
      }

      let usernameData = (username.uppercased() + domain).data(using: .utf16LittleEndian)!
      let responseKeyNT = Crypto.hmacMD5(key: Data(passwordHash), data: usernameData)

      return Data() + responseKeyNT
    }

    func authenticateMessage(
      username: String? = nil,
      password: String? = nil,
      domain: String? = nil,
      negotiateResponse: Negotiate.Response,
      negotiateMessage: NegotiateMessage
    ) -> AuthenticateMessage {
      let responseKeyNT = ntowfv2(
        username: username ?? "",
        password: password ?? "",
        domain: domain ?? ""
      )

      let clientChallenge = Crypto.randomBytes(count: 8)

      let ntlmv2ClientChallenge = NTLMv2ClientChallenge(
        challengeFromClient: clientChallenge,
        avPairs: targetInfo
      )

      let temp = ntlmv2ClientChallenge.encoded()

      let ntProofStr = Crypto.hmacMD5(key: responseKeyNT, data: Data() + serverChallenge + temp)
      let sessionBaseKey = Crypto.hmacMD5(key: responseKeyNT, data: ntProofStr)

      let randomData = Crypto.randomBytes(count: 16)
      let encryptedRandomSessionKey = Crypto.rc4(key: sessionBaseKey, data: randomData)

      let ntChallengeResponse = ntProofStr + temp

      let authenticateMessage = NTLM.AuthenticateMessage(
        ntChallengeResponse: ntChallengeResponse,
        userName: username,
        encryptedRandomSessionKey: Data(encryptedRandomSessionKey)
      )

      let mic = Crypto.hmacMD5(
        key: randomData,
        data: negotiateResponse.securityBuffer + negotiateMessage.encoded() + authenticateMessage.encoded()
      )

      return NTLM.AuthenticateMessage(
        ntChallengeResponse: ntChallengeResponse,
        userName: username,
        workstationName: "",
        encryptedRandomSessionKey: Data(encryptedRandomSessionKey),
        mic: Data(mic)
      )
    }
  }

  public struct AuthenticateMessage {
    public let signature: UInt64
    public let messageType: UInt32
    public let lmChallengeResponse: Fields
    public let ntChallengeResponse: Fields
    public let domainName: Fields
    public let userName: Fields
    public let workstationName: Fields
    public let encryptedRandomSessionKey: Fields
    public let negotiateFlags: NegotiateFlags
    public let version: UInt64
    public let mic: Data

    public init(
      ntChallengeResponse: Data,
      domainName: String? = nil,
      userName: String? = nil,
      workstationName: String? = nil,
      encryptedRandomSessionKey: Data? = nil,
      mic: Data = Data()
    ) {
      signature = 0x4e544c4d53535000
      messageType = 0x00000003
      lmChallengeResponse = Fields(
        value: Data(count: 24),
        offset: 8 + // signature
                4 + // messageType
                8 + // LmChallengeResponseFields
                8 + // NtChallengeResponseFields
                8 + // DomainNameFields
                8 + // UserNameFields
                8 + // WorkstationFields
                8 + // EncryptedRandomSessionKeyFields
                4 + // NegotiateFlags
                8 + // Version
                16  // MIC
      )
      self.ntChallengeResponse = Fields(value: ntChallengeResponse, offset: lmChallengeResponse.bufferOffset + UInt32(lmChallengeResponse.len))
      self.domainName = Fields(value: domainName, offset: self.ntChallengeResponse.bufferOffset + UInt32(self.ntChallengeResponse.len))
      self.userName = Fields(value: userName, offset: self.domainName.bufferOffset + UInt32(self.domainName.len))
      self.workstationName = Fields(value: workstationName, offset: self.userName.bufferOffset + UInt32(self.userName.len))
      self.encryptedRandomSessionKey = Fields(value: encryptedRandomSessionKey ?? Data(), offset: self.workstationName.bufferOffset + UInt32(self.workstationName.len))

      negotiateFlags = [
        .negotiate56,
        .negotiateKeyExchange,
        .negotiate128,
        .negotiateVersion,
        .negotiateTargetInfo,
        .negotiateExtendedSecurity,
        .negotiateTargetTypeServer,
        .negotiateAlwaysSign,
        .negotiateNetware,
        .negotiateSeal,
        .negotiateSign,
        .requestTarget,
        .unicode,
      ]

      version = UInt64(0x000a02000000000f).bigEndian
      self.mic = mic.isEmpty ? Data(count: 16) : mic
    }
    
    public func encoded() -> Data {
      var data = Data()
      data += signature.bigEndian
      data += messageType
      data += lmChallengeResponse.encoded()
      data += ntChallengeResponse.encoded()
      data += domainName.encoded()
      data += userName.encoded()
      data += workstationName.encoded()
      data += encryptedRandomSessionKey.encoded()
      data += negotiateFlags.rawValue
      data += version
      data += mic
      data += lmChallengeResponse.value
      data += ntChallengeResponse.value
      data += domainName.value
      data += userName.value
      data += workstationName.value
      data += encryptedRandomSessionKey.value
      return data
    }
  }

  public struct NegotiateFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
      self.rawValue = rawValue
    }

    public static let negotiate56 = NegotiateFlags(rawValue: 0x80000000)
    public static let negotiateKeyExchange = NegotiateFlags(rawValue: 0x40000000)
    public static let negotiate128 = NegotiateFlags(rawValue: 0x20000000)
    public static let negotiateVersion = NegotiateFlags(rawValue: 0x02000000)
    public static let negotiateTargetInfo = NegotiateFlags(rawValue: 0x00800000)
    public static let requestNonNTSessionKey = NegotiateFlags(rawValue: 0x00400000)
    public static let negotiateIdentify = NegotiateFlags(rawValue: 0x00100000)
    public static let negotiateExtendedSecurity = NegotiateFlags(rawValue: 0x00080000)
    public static let negotiateTargetTypeServer = NegotiateFlags(rawValue: 0x00020000)
    public static let negotiateTargetTypeDomain = NegotiateFlags(rawValue: 0x00010000)
    public static let negotiateAlwaysSign = NegotiateFlags(rawValue: 0x00008000)
    public static let negotiateOemWorkstationSupplied = NegotiateFlags(rawValue: 0x00002000)
    public static let negotiateOemDomainSupplied = NegotiateFlags(rawValue: 0x00001000)
    public static let negotiateAnonymous = NegotiateFlags(rawValue: 0x00000800)
    public static let negotiateNetware = NegotiateFlags(rawValue: 0x00000200)
    public static let negotiateLanManagerKey = NegotiateFlags(rawValue: 0x00000080)
    public static let negotiateDatagramStyle = NegotiateFlags(rawValue: 0x00000040)
    public static let negotiateSeal = NegotiateFlags(rawValue: 0x00000020)
    public static let negotiateSign = NegotiateFlags(rawValue: 0x00000010)
    public static let requestTarget = NegotiateFlags(rawValue: 0x00000004)
    public static let oem = NegotiateFlags(rawValue: 0x00000002)
    public static let unicode = NegotiateFlags(rawValue: 0x00000001)
  }

  public struct Fields {
    public let len: UInt16
    public let maxLen: UInt16
    public let bufferOffset: UInt32
    public let value: Data

    public init(value: Data, offset: UInt32) {
      len = UInt16(value.count)
      maxLen = len
      bufferOffset = offset
      self.value = value
    }

    public init(value: String?, offset: UInt32) {
      let data = Data() + (value ?? "")
      len = UInt16(data.count)
      maxLen = len
      bufferOffset = offset
      self.value = data
    }

    public func encoded() -> Data {
      var data = Data()
      data += len
      data += maxLen
      data += bufferOffset
      return data
    }
  }
}

struct NTLMv2ClientChallenge {
  let respType: UInt8
  let hiRespType: UInt8
  let reserved1: UInt16
  let reserved2: UInt32
  let timeStamp: UInt64
  let challengeFromClient: Data
  let reserved3: UInt32
  let avPairs: Data

  init(challengeFromClient: Data, avPairs: Data) {
    respType = 0x01
    hiRespType = 0x01
    reserved1 = 0x0000
    reserved2 = 0x00000000
    
    let now = Date()
    let fileTime = FileTime(now)

    self.timeStamp = fileTime.raw
    self.challengeFromClient = challengeFromClient
    reserved3 = 0x00000000
    self.avPairs = avPairs
  }

  func encoded() -> Data {
    var data = Data()
    data += respType
    data += hiRespType
    data += reserved1
    data += reserved2
    data += timeStamp
    data += challengeFromClient
    data += reserved3
    data += avPairs
    data += Data(count: 8)
    return data
  }
}

struct AVPair {
  let avId: AVId
  let avLen: UInt16
  let avValue: Data

  enum AVId: UInt16 {
    case eol = 0x0000
    case nbComputerName = 0x0001
    case nbDomainName = 0x0002
    case dnsComputerName = 0x0003
    case dnsDomainName = 0x0004
    case dnsTreeName = 0x0005
    case flags = 0x0006
    case timestamp = 0x0007
    case singleHost = 0x0008
    case targetName = 0x0009
    case channelBindings = 0x000a
  }

  init(avId: AVId, avValue: Data) {
    self.avId = avId
    avLen = UInt16(avValue.count)
    self.avValue = avValue
  }

  init(data: Data) {
    let reader = ByteReader(data)
    avId = AVId(rawValue: reader.read())!
    avLen = reader.read()
    avValue = reader.read(count: Int(avLen))
  }
  
  func encoded() -> Data {
    var data = Data()
    data += avId.rawValue
    data += avLen
    data += avValue
    return data
  }
}