import Foundation
@testable import Xit

struct StringOID: OID
{
  let sha: String
  var isZero: Bool { return sha == "00000000000000000000" }
}

extension StringOID: Equatable
{
}

func == (left: StringOID, right: StringOID) -> Bool
{
  return left.sha == right.sha
}

extension StringOID: Hashable
{
  public func hash(into hasher: inout Hasher)
  {
    hasher.combine(sha)
  }
}

prefix operator §

prefix func § (_ string: String) -> StringOID
{
  return StringOID(sha: string)
}
