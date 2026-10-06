# Testing a release on another Kali computer

Outside test reports help us find problems on a separate Kali installation. The
maintainer waived this requirement for 2.0.0; reports remain welcome. No specialist
knowledge is required. Use Kali on an Intel/AMD 64-bit
computer, with at least 4096 MB allocated memory. Make a VM snapshot before installation.

Wait until the named release is actually published. Replace the tag below only if the
maintainer asks you to test another version. Keep the installation folder for rollback.

```bash
sudo apt update
sudo apt install git
git clone --branch v2.0.0 --depth 1 https://github.com/JijoShibu/revctf.git revctf-2.0-test
cd revctf-2.0-test
sudo ./install.sh
revctf --version
```

Run `bash tools/test-reliability.sh`, `bash tools/test-resources.sh`, and
`bash tools/test-accuracy.sh`. Save their results, including any skips or failures.
The accuracy tests create small harmless examples. They do not require private challenges.

For a full controlled Linux scan, install the test compiler, build the samples, and run:

```bash
sudo apt install build-essential
bash tools/build-test-corpus.sh
revctf scan test-corpus/crackme --no-tui --output "$HOME/revctf-2.0-test-check"
test-corpus/crackme sw0rdf1sh
test-corpus/crackme deliberately-wrong
```

The known correct password must be accepted and the deliberately wrong one rejected.
This sample takes its password after the program name, rather than through keyboard input.
Look for `sw0rdf1sh` in the saved Ghidra output. A possible flag marked UNVERIFIED is a
lead; it is not proof of acceptance. Exit code 2 means at least one requested step was
incomplete. Report that result even if another step found the answer.

After installation, disconnect the VM's network and repeat the scan with a **new** output
folder. It should use the installed tools without downloading anything.

Open a GitHub issue using the bug-report form. Include:

- The exact release version and source commit (`git rev-parse HEAD`).
- Kali version (`cat /etc/os-release`), allocated RAM, and `free -m` output.
- Installation result, test totals, every failure or skip, and commands used.
- Whether the correct password was found and independently accepted.
- Whether offline scanning worked and whether any test container remained running.

Remove passwords, account tokens, personal paths, and private challenge material.
Only the known public test password above belongs in this report. The maintainer will
review the issue and record its findings for fixes and future release decisions.
