# age

Encrypts files. Small, simple, and with no accounts or key servers: you hand someone a
short public key and they can send you files only you can open.

## Install

`age-v<version>-linux-amd64.tar.gz`, `-linux-arm64`, `-darwin-arm64`, or `-windows-amd64.zip`.
Each holds two programs, `age` and `age-keygen`.

```
tar xzf age-v*-linux-amd64.tar.gz
sudo cp age/age age/age-keygen /usr/local/bin/
age --version
```

## First steps offline

Make your key pair. The file is your private key: keep it safe and back it up.

```
age-keygen -o key.txt
```

It prints your public key, a line starting with `age1`. Give that to anyone.

Encrypt a file for someone (use their `age1...` key):

```
age -r age1examplepublickey -o secrets.tar.age secrets.tar
```

Decrypt a file sent to you:

```
age -d -i key.txt -o secrets.tar secrets.tar.age
```

With no keys at all, a passphrase works: `age -p -o notes.age notes.txt`, then
`age -d -o notes.txt notes.age`.

SSH keys work as well: `age -R ~/.ssh/id_ed25519.pub` to encrypt, `age -d -i ~/.ssh/id_ed25519` to decrypt.
