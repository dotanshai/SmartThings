-- Shared TLS client certificate baked into every install of this driver.
--
-- IMPORTANT: this certificate/key pair is the SAME for every user of this
-- driver (see README.md for why -- it's a deliberate simplicity/security
-- tradeoff). Once a TV has been paired against it, anyone on that TV's
-- local network who also has this key (i.e. a copy of this driver's
-- source) can control it without repeating the on-screen pairing step.
-- Keep that in mind before relying on this for anything sensitive.
--
-- Generated as a proper end-entity client-auth certificate (CA:FALSE,
-- keyUsage=digitalSignature+keyEncipherment, extendedKeyUsage=clientAuth)
-- -- an earlier version of this cert was accidentally a CA:TRUE
-- self-signed root (openssl's default for `req -x509` without explicit
-- extensions), which several real Google TVs silently refuse to
-- continue pairing with even though the raw TLS handshake still
-- succeeds and the initial PairingRequest still gets acked.
local M = {}

M.CERT_PEM = [[
-----BEGIN CERTIFICATE-----
MIIDPzCCAiegAwIBAgIUBOiD5pFr/C4SlmaYMLbqc95RzjEwDQYJKoZIhvcNAQEL
BQAwHjEcMBoGA1UEAwwTU21hcnRUaGluZ3NHb29nbGVUVjAeFw0yNjA3MzAwNDUx
MzRaFw00NjA3MjUwNDUxMzRaMB4xHDAaBgNVBAMME1NtYXJ0VGhpbmdzR29vZ2xl
VFYwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDIZYsVlLlGX0wzZ2fF
zXU9BPS2DLqAoz1ZMUUtPv/D+OLcuEPZR1ZnH6tuQSCgLJshZJfJ1mW8M37Tvue/
mg4ZTWijziru04yvNxLhLuAK3ePMBNmU7J/EHC5ciMUpQovU8jlYg4Bl7PI7f2N3
clc1ACkYOUmQ7Oz8Ib4L2wd+DZ7D6Mp5pyB6cMmOzDe56dtdPzU1u51YnTzMOR+R
cbww7OUr9H6ngxkPqrrrHwLTAce+UB9F4/DfmkGTQ0RNjz0vf+V4lyQPZZse26dj
Q7QO2q2U0GZTWEND/Cyezw+6zxjSkfOJpim/uVjKdMQ9THso3mSqur9hf3H/h85K
DKKRAgMBAAGjdTBzMB0GA1UdDgQWBBTCuMV47ngaJe1NAMj4kgiR2tFUrTAfBgNV
HSMEGDAWgBTCuMV47ngaJe1NAMj4kgiR2tFUrTAMBgNVHRMBAf8EAjAAMA4GA1Ud
DwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDAjANBgkqhkiG9w0BAQsFAAOC
AQEAjB9LYdAK5Gl6adEBB/oVpBwbMJZp8yJgwXXWZ+MFPNsJ5CwG6L/FSszPoO1e
ExmYDfgxRk18B8bbCUkqEUzsm2z6V083o7LWmgj3CI/i5rc/W7OKLXEKzbPARPi5
zX67crmZMtYnPFykdrdCYQnxcDFrcRMAOn2OApg6XTrKWZ1Pkev9NtpNCRHhS1lL
TJnevp2MyXjB1O7Z/oocu/8nXbgknx+nQQU42FvFv75NXut5Noh6GcMLqXLlkVaW
t+xK4mf5u2bVEe94tp0ismVmZfT0Zq4h7F+4Dfh4OEkXuv/rGKp3bI5RE5EAlBeH
2jtkWpnWJYoSJZGGQuM6O9iSdQ==
-----END CERTIFICATE-----
]]

M.KEY_PEM = [[
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDIZYsVlLlGX0wz
Z2fFzXU9BPS2DLqAoz1ZMUUtPv/D+OLcuEPZR1ZnH6tuQSCgLJshZJfJ1mW8M37T
vue/mg4ZTWijziru04yvNxLhLuAK3ePMBNmU7J/EHC5ciMUpQovU8jlYg4Bl7PI7
f2N3clc1ACkYOUmQ7Oz8Ib4L2wd+DZ7D6Mp5pyB6cMmOzDe56dtdPzU1u51YnTzM
OR+Rcbww7OUr9H6ngxkPqrrrHwLTAce+UB9F4/DfmkGTQ0RNjz0vf+V4lyQPZZse
26djQ7QO2q2U0GZTWEND/Cyezw+6zxjSkfOJpim/uVjKdMQ9THso3mSqur9hf3H/
h85KDKKRAgMBAAECggEABSRB1Mxrkogoats42OTkIKwrYS5jbKCDlvHCLh6DLnKI
05PwvbbsWxn/aoVGQoXSdyFfGaEkHBeQJfusc4iO2wxW5nkINfd8kRRPKjLrMawu
x5HKSV1m3f/BGsOxl1TrRIvwd7psBXF2Z5tloG9xGF2IMGRr5EmH7RIqj6BPiWbh
bwjEauFFhIV9PCXy6K4uTlomyhP7HoE2fDjMgOoKy+FXH1EHFmyhYt+oLgFD1Nnm
dh4+jSuW+GoTfp46Ti/3c0f/9B9T5BL2pcFWbI8ELkT9Y8GA341nu5QBT+RHY2od
ZDDK8vH9P1ZjRjUbFTWyDKxsOv1Qf7i3u4nRe3sclwKBgQDoWDlAF+UqNiH6z6le
1NON/2puB5kAtIRNpa41uUQzxEVtsTH0gVsiAGVIZkH3h9ICIBmGRrHdwJlr2kiv
pWiFCJc9GCj9OhL8wEXcg9TTsH/hqEjrvteYCFiM1ukYRvbSdV7BwToEEmc+rEc4
pzpMS6R3UjuyA2YKlUA9S2jB9wKBgQDczKKbaTBa7qtB5iizMc4QYyqL7AUL27FB
wOA2ZCkCdeuYkaZjj+7m68qnUsiEFRq27G+Wa/QDcHJ/5ya+TwvnO+0c+k6ijB1z
jin5x7Ekh+Q/5bHIhWNRfLAMf99gn9fZAXG+9DPJhOELB/fpKzqQjJ3j/vgqNmgL
pgcp4RcdtwKBgBDh6DcKBXLNwCZTVIE5ga29s2QPVUTB2SMzOLdaoOQKDOltiK21
gIO196YNGBn+WnohDvm8xUvRpNQ7ZjCtGi0gdKzRxpiv0ZVf+zOMuLgxCPnCmpnW
oh+/639AVmuXLHQaZyo4+hg1ph7dscciD5BfprGs3f2PVajLM4HAqvn9AoGBAIom
K3OLnCq4/EROKpb8CY9tTJihgwLJYZ3ffSnq/1G/0Dn0n6PZ0cOAMpsAi99AiSd8
xdDbGKDyQWHPkgku0ibK8u/XmU3Q1ziO8aqMDETsFZ75K4RoGR1KI6iedXgyas4n
PjEZADINRvUs9itY1drNcJjP1hwrUGxBZGgKovj/AoGAEdBhOnHm+BdGSQHytcqJ
++f6vsQ+Rg6idoR3rFpoV3F/BQvqQsDgb/v0vlhcGFTUxtjaev0DTa+1/N6umqa/
OO3GAxpX1K4hxmP9WzDOPqIruY+IXr5HVhkHH+LVk0GASTo8Kygf5J9IU8JljB9L
nxySRf63rX1h8xik7YNfN4Y=
-----END PRIVATE KEY-----
]]

return M
