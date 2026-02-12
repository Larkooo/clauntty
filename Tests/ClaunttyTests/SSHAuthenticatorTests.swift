import XCTest
@testable import Clauntty

final class SSHAuthenticatorTests: XCTestCase {
    private func makeAuthenticator() -> SSHAuthenticator {
        SSHAuthenticator(
            username: "testuser",
            authMethod: .sshKey(keyId: "test-key"),
            connectionId: UUID()
        )
    }

    func testParseOpenSSHRSAKey() throws {
        let authenticator = makeAuthenticator()
        let keyData = Data(openSSHRSAKey.utf8)

        let key = try authenticator.parsePrivateKey(data: keyData, passphrase: nil)
        let publicKey = String(openSSHPublicKey: key.publicKey)
        XCTAssertTrue(publicKey.hasPrefix("ssh-rsa "), "Expected ssh-rsa public key prefix")
    }

    func testParsePEMRSAKey() throws {
        let authenticator = makeAuthenticator()
        let keyData = Data(pemRSAKey.utf8)

        let key = try authenticator.parsePrivateKey(data: keyData, passphrase: nil)
        let publicKey = String(openSSHPublicKey: key.publicKey)
        XCTAssertTrue(publicKey.hasPrefix("ssh-rsa "), "Expected ssh-rsa public key prefix")
    }
}

private let openSSHRSAKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEA7ahsYA8MEsm1acMuUGakw0pYeEm7oCoQ135EMTb7x/g5lTrkVDMl
7Xom92+Uni8AMF6Oa+oW0gllUvHRb13juRZLPEKQvkVVlYnVHlEe05g35lq08uwHhpppun
msqOn5yvS9Jvzh8xepZ5a6ehiqwfmBkRLmkbKrofSVomDLEXm+j+FwLufSYYhgBlea3O38
e8NT+3XOiwsKSgiAmcVuGgUjuho8QDEuZZA8TkCBfJQh/wjzvk9cfrNE0jbb6qG8kJCR5d
W4l/B4iHbC5Cg8sMbA7e2hMpnueJ3sHSXPO8feWbWYNFpdDi/QVFDiTARSm/YeYreiO7Ew
JwenqiifCwAAA9iSyAjYksgI2AAAAAdzc2gtcnNhAAABAQDtqGxgDwwSybVpwy5QZqTDSl
h4SbugKhDXfkQxNvvH+DmVOuRUMyXteib3b5SeLwAwXo5r6hbSCWVS8dFvXeO5Fks8QpC+
RVWVidUeUR7TmDfmWrTy7AeGmmm6eayo6fnK9L0m/OHzF6lnlrp6GKrB+YGREuaRsquh9J
WiYMsReb6P4XAu59JhiGAGV5rc7fx7w1P7dc6LCwpKCICZxW4aBSO6GjxAMS5lkDxOQIF8
lCH/CPO+T1x+s0TSNtvqobyQkJHl1biX8HiIdsLkKDywxsDt7aEyme54newdJc87x95ZtZ
g0Wl0OL9BUUOJMBFKb9h5it6I7sTAnB6eqKJ8LAAAAAwEAAQAAAQEAigsBYE59MdCOGm+v
0C2+2FyvxLb3T9H/VFxYWcnZN88cC21YwPuwtR710VWzmqosTuwth8tCFCA3BZXGlAySQK
kNbGQx1QNK8gBMlT6DTF6nYZsgbdXhjTLV5OXV/4tgd53u3N2YlO4SjUQE7vSzAtbdhpnW
6ZxBi2IZJGdarLvO7UbwjSIjulIjvAKXiGY4a3UDZLAIPGF1mnEmLTVRQ8hdBgawpUky8n
Xj2blU19iLQgKS/N7SIVaUY1ixIYqPMEymZhEpebh5JGDaHrTzpgvQzIN7/EK9kylmFu4D
CjiKlPYmdBxdpIPEd+utx2c3iJ/baw2U1QQAdGM9TBQh8QAAAIEAsHmW1eVqrmJ9R9sk+y
I06gjGNONaxAqwXiOFMZ3c2+FqGZfihuiLTxjWy5hvOHmX+KEkw5dBeWgOQu4lwEUCEGEi
OXMGtlpKP7K5o6V97zosdbzqE3MyED6a0fgcv+GGn0MuItQXIiaYJrM6cDv9FgI6PDyKmd
zPxngmbFLD2CMAAACBAPzXaxllGPbtT88l6nBOyZvAqa9/ZZDKZSE72K/Beiz/cxNKgFTy
d7o9AunJEppAMeyr6RIlV5xuDHX83xUE71odHnJJXFfqZ5PrgyiDeCXbRRXMqJmBPD6H2+
D1oEFnH0cHZ18+wd7HyscHw0YYfhoUTDV+U4Vbmb4Z2SJf+PzpAAAAgQDwoHK/wFrTRfen
74WWdSrLcfFf0xT2cdp+Pj7EnBhllFXsiQzqmxHMXZfU1u8Ix2ZgiSXAjgAoDyPyw/VQL6
4yXI4WhxW8k1kWBcYhzvNBhjPOwbgayWqWPrUcF6giVIsvHweDYgz8MAt3Y55ubjMne7DL
u7R0+2qTnP9hcYfz0wAAAB5uYXNyQE5hc3JzLU1hY0Jvb2stUHJvLTMubG9jYWwBAgM=
-----END OPENSSH PRIVATE KEY-----
"""

private let pemRSAKey = """
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEArbFm+DDovLasfPSdgRLwVKlJxVfGfJ9kXS4rVL5s67qWpEu3
FrLvR2TJmUm71bntgSCSCJBzPRlyFE4SHJkNXoAS+CaY3Zt8zQlyizsraZNA55C7
H+vaCumVfIQQhRlx/CK9JTXbBEmurvcjtOHrv9pW2f/X2wmJWk2+YDolvuDxsdP0
TMW3MltmMvSaHmPnsQS3kGjIREvvATktTvTATUkV/6D1ybq/44LbBPE1oMKsXqVM
pb+nGvUyAwjiX/xM+Oioc3lP+TUdAR2AaZR/7HlH17YPt4aV40nCTVRiop6KpzMC
xaKuam8IP1S0/28uWaFEEFTWcv5n5ZbFyfPjawIDAQABAoIBAB/ITmcry+p8IqPa
vtdXd9KGB5Gstg0nvV2vjQ48qgGYaug1UpM8urv9nUYHT++TzfnK0+3tQKj1dwJw
JrBE8UVReiceKOqkAPojuGnxscfnwgCdYyA8L/G/PDNElyFDvq+8S4/7gtAOC4DI
iCgZDuJUOYA6aG0UGaYEg8ln2nBKu6M3xEozwVRgsT21ax3LnmIl97LoffwStFKC
b9S9afsA9XxOTjmvK+gWpV31KgVtbE+xk/FBwND0aIknMFkPQYJ4Z1HAf65yanb9
7qFXXz4w6dZEttXEtxAPu8+vRcACCnRkxC6PxWNlG0rzus0LUFtXNu8yHtYomgDQ
NLp3wMECgYEA30J5D4+Z0JmHwn9Mr+CfO4gcPpeSXZqAtMPLkH2SDIfH1J7rN1kh
B2jE/2+H+smgogIPmadU80tKYH7XwLqX75KC73zw+VCbOlGeR8NwBXDgiZUS7TBW
nhbCbbfTjJ46NHhxk902DfZN7K3RbX9ofIahlMlLFJFUvyVE8smVkO0CgYEAxyod
w7x8xnzGikokZXno9aShjyegmgr0CR1ZEaY8pT8JstWdGPQoM/g1+ISe2vono50D
mq62JKOqRjYmrojhUkMs/DRb56x7+rxMCbMqGgs4QGmbK4bFIIN10/+ptRJmgRT7
/6ijiKXF8FwUUea0mswtPAjZ+xZGbqfZ0WhHMrcCgYEAmyvqVGRsdc2fzBEKTduD
EK9jYiWa9y/hcMH9BCoijk75FtB1j3yFNk8dTKRKEIZ+/NsN2K+ynX6g7Tx73FpU
K5DbLHTcT4w0t23u4tX1T/LKPRW9l9lW+n27GOMBR+TZc4qa9jhzz3R3aJ7Oxpod
Fx/DwlO9uUfhbREMQOrW52kCgYA5ISSek/+6s+oDmxbroNepNss9FCHmbgPoZWm6
PVQiFn4CtXG1ybuKhMV+fxROPfmG3jA9e6Y1xli+gSQBZrQzc5+AzMgcIYcCumaZ
VbJa/CLrnx9qkeMT24G+CRU2IowStOFASbB3Lw4jT1Zo0+O0j6LeGK/mbVJQxYce
oWni6wKBgGM6z/xTJmXtPEBXmUOzoU8beMpHMcV3GosU8uFqDBCAxJRKWOwJ0t/0
cMPZ0XqGx2UgsNCS5bktXZr7KHFI4lmIz1KQ9+43SUG+KyLPHG2EdOHSEi73Xn2a
2sEelVzDUnIwHarSs/tiqrWGF/GlNMsG/lwu9rtOekXHklrr0/43
-----END RSA PRIVATE KEY-----
"""
