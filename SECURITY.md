# Security

Report vulnerabilities through [GitHub's private reporting form](https://github.com/JijoShibu/revctf/security/advisories/new).
Include the version, command, environment, and a small example that we may share with other maintainers.
Remove passwords, personal information, and private challenge material. Do not publish an exploit against another person's service.

The supported release line is 2.0. Stable 2.0 support begins with publication of 2.0.0;
1.x does not provide the same resource and incomplete-result safeguards.
Confirmed problems affecting answers, installation, saved files, isolation, or resource limits
block publication. Security fixes use a new release; published tags are never moved.
Response times depend on maintainer availability.

Use a disposable Kali amd64 VM for untrusted files. Keep personal files, shared folders,
clipboard sharing, and account credentials outside that VM. Run scans as an ordinary user.
Docker access grants powerful host access, and containers share the VM's kernel.
The tracing stages run challenges in containers; static parsers and custom Ghidra scripts
run in the VM itself. Review custom scripts before using them.

Dependencies have a recorded profile. Propose upgrades separately, check upstream advisories,
and repeat affected tests before adoption. Pinning is a reproducibility measure, not a promise
that a dependency has no defects. Installation requires network access; prepared scans work offline.

Maintainer: Jijo Shibu <jijoshibu@gmail.com>.
