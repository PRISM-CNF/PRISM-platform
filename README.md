# PRISM Platform

Kubernetes, Network Service Mesh and OVS deployment, monitoring and resource
pressure source tools. Requires Linux, Bash 4.3+, Python 3, kubectl and an
existing Kubernetes cluster. Container images referenced by the manifests must
be accessible to the cluster.

```sh
./bin/nsm-ovs-lab --help
./bin/nsm-ovs-lab show-config
./bin/nsm-ovs-lab deploy-basic
./bin/nsm-ovs-lab check-basic
./bin/nsm-ovs-lab deploy-gateway --stack-id demo
```

Review the manifests and configure your node names, registry access, kubeconfig
and context before deployment. `config/clusters/vm-lab.env` is a generic profile;
use `--cluster-profile /path/to/profile.env` for your own profile. Local overrides
may be placed in ignored `config/cluster.env`. Bundled assets are used directly;
private source repositories and synchronization locks are not required for
deployment. Source-build bootstrap commands need separately supplied source
repositories or explicit repository URL overrides.

For VPN, render with `render-vpn-stack --stack-id demo` and inspect the namespace
shown by `show-vpn-plan --stack-id demo`. Create that namespace and two Secrets,
`vpn-encrypt-wg` and `vpn-decrypt-wg`, before `deploy-vpn`. Each Secret must contain
`privatekey` and `peer_publickey` files: the endpoint's own WireGuard private key
and the other endpoint's public key. Generate fresh keys for your environment;
no key material is bundled. Secrets are managed separately from manifests.

Sampling and pressure primitives live in `scripts/measurement/`,
`scripts/host-measurement/`, and `scripts/pressure/`. Select the target CPU set
explicitly using the tool's options; the pressure default is CPU 0 and can be
overridden with `NSM_OVS_PRESSURE_CPUSET`. Do not run pressure tools on a shared
cluster without choosing suitable resources.

See `PROVENANCE.md` for the source snapshot.
