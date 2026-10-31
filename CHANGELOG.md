# Changelog

## [1.2.0](https://github.com/ithaca-lab-org/idp-infra/compare/v1.1.0...v1.2.0) (2026-10-31)


### Features

* **bootstrap:** portal image push identity and portal session secret ([#20](https://github.com/ithaca-lab-org/idp-infra/issues/20)) ([8af15a3](https://github.com/ithaca-lab-org/idp-infra/commit/8af15a31ebf5a621cadaa0b6ae64046ba4ccd959))
* **pubsub:** order-events topic, notifier subscription and workload identities ([#28](https://github.com/ithaca-lab-org/idp-infra/issues/28)) ([ce71bfa](https://github.com/ithaca-lab-org/idp-infra/commit/ce71bfa26194b81e7f128479ff1a8aa213b7d338))
* **registry:** make image tags immutable ([#21](https://github.com/ithaca-lab-org/idp-infra/issues/21)) ([ebb6a11](https://github.com/ithaca-lab-org/idp-infra/commit/ebb6a11edd2cf6a5ce4e317755d390d9757b5136))
* repeatable rebuilds (verify the portal stack, seed password, Tailscale cleanup) ([#25](https://github.com/ithaca-lab-org/idp-infra/issues/25)) ([9b1a31d](https://github.com/ithaca-lab-org/idp-infra/commit/9b1a31ddf5ef951ac7e2ec11d3fbd0f5f84df1e5))
* **secrets:** MongoDB credentials for the portal order store ([#24](https://github.com/ithaca-lab-org/idp-infra/issues/24)) ([86b96f9](https://github.com/ithaca-lab-org/idp-infra/commit/86b96f9236118b13b57910e989756747084c9f92))
* **vault:** add vault-proof.sh to prove per-namespace Vault isolation ([#35](https://github.com/ithaca-lab-org/idp-infra/issues/35)) ([6ebfb00](https://github.com/ithaca-lab-org/idp-infra/commit/6ebfb0051f156e2cac2ecbd75e6a99c916686b70))
* **vault:** KMS auto-unseal key, vault GSA, one-time init and verify step 8 ([#31](https://github.com/ithaca-lab-org/idp-infra/issues/31)) ([4f3622b](https://github.com/ithaca-lab-org/idp-infra/commit/4f3622ba0749e5841ad04bff0a235f3e26ab778c))
* **verify:** check the notifier and order-event publishing in step 7 ([#30](https://github.com/ithaca-lab-org/idp-infra/issues/30)) ([d3fe805](https://github.com/ithaca-lab-org/idp-infra/commit/d3fe8051c3282b0b6daf9fdbd533029f0530bc04))
* **verify:** smoke namespace gets its Vault access objects when VAULT_ENABLED ([#34](https://github.com/ithaca-lab-org/idp-infra/issues/34)) ([ec4a702](https://github.com/ithaca-lab-org/idp-infra/commit/ec4a70245b31150d264717d1e56926d868e0297f))


### Bug Fixes

* **ci:** plan identity can read the budget; PR plan fails on terraform errors ([#33](https://github.com/ithaca-lab-org/idp-infra/issues/33)) ([9456867](https://github.com/ithaca-lab-org/idp-infra/commit/945686771f4efcd4f95f68d1236610c52dd4263e))
* **scripts:** tailscale-cleanup also removes the argocd-admin device ([#27](https://github.com/ithaca-lab-org/idp-infra/issues/27)) ([fc21f85](https://github.com/ithaca-lab-org/idp-infra/commit/fc21f859404c26956f1ed51da08a0082c0566a96))
* **secrets:** apply Opus review findings (CI role, rotation docs, tailnet read) ([#18](https://github.com/ithaca-lab-org/idp-infra/issues/18)) ([19be0d3](https://github.com/ithaca-lab-org/idp-infra/commit/19be0d3fee29f41602cfeb818e7e37c32f34843b))
* **vault-unseal:** service account id vault-server; fail PR plan on terraform errors ([#32](https://github.com/ithaca-lab-org/idp-infra/issues/32)) ([a7d5381](https://github.com/ithaca-lab-org/idp-infra/commit/a7d538167ad755e65b04a0dd0cf6df4dd70461e0))
* **vault:** vault-proof.sh logs in via Kubernetes auth, no generate-root ([#36](https://github.com/ithaca-lab-org/idp-infra/issues/36)) ([1706e41](https://github.com/ithaca-lab-org/idp-infra/commit/1706e4199a6404fd15afc6156420227e9e4871e0))
* **vault:** vault-proof.sh reads a silent exit 2 from vault list as a missing path ([#38](https://github.com/ithaca-lab-org/idp-infra/issues/38)) ([1e2ce24](https://github.com/ithaca-lab-org/idp-infra/commit/1e2ce24c4d15c0b58cf2e28c6634069d0d846d70))
* **vault:** vault-proof.sh treats 'No value found' as gone ([#37](https://github.com/ithaca-lab-org/idp-infra/issues/37)) ([d1f3112](https://github.com/ithaca-lab-org/idp-infra/commit/d1f31126c641f4ea2d17bc3e66804545bc945083))

## [1.1.0](https://github.com/ithaca-lab-org/idp-infra/compare/v1.0.0...v1.1.0) (2026-10-19)


### Features

* **secrets:** generate and inject identity secrets ([#15](https://github.com/ithaca-lab-org/idp-infra/issues/15)) ([f3f5721](https://github.com/ithaca-lab-org/idp-infra/commit/f3f572120e8fc906c35d6f8faae9cdd2d78c7e52))

## 1.0.0 (2026-10-14)


### Features

* bootstrap Tailscale OAuth secret at make up, verify operator (Step 6) ([#10](https://github.com/ithaca-lab-org/idp-infra/issues/10)) ([7f3894e](https://github.com/ithaca-lab-org/idp-infra/commit/7f3894e4b1bfd6df1aab8bf88aa0f90d954cfbae))
* install Argo CD via Terraform and add real verify.sh (Step 6) ([#8](https://github.com/ithaca-lab-org/idp-infra/issues/8)) ([4f7565f](https://github.com/ithaca-lab-org/idp-infra/commit/4f7565f8ae64f18b7b16e5f3dd2e5762c1226928))
* static ingress IP, wildcard DNS and cert-manager DNS-01 identity ([#11](https://github.com/ithaca-lab-org/idp-infra/issues/11)) ([98e36a9](https://github.com/ithaca-lab-org/idp-infra/commit/98e36a9bcbc5028c271c316c815436cb595e3441))
* step 5 modules (network, gke, kms, registry, dns, budget) ([#1](https://github.com/ithaca-lab-org/idp-infra/issues/1)) ([24f3dae](https://github.com/ithaca-lab-org/idp-infra/commit/24f3dae23c7c6c71e5eeda7348cae518ea2fc777))
* verify echo app end to end, ADR 0006 (staging certificates) ([#12](https://github.com/ithaca-lab-org/idp-infra/issues/12)) ([1948176](https://github.com/ithaca-lab-org/idp-infra/commit/19481765e383cdbdac92890416b3b163520a1780))
* **verify:** show per-step progress and a summary of every check ([#13](https://github.com/ithaca-lab-org/idp-infra/issues/13)) ([c7193f5](https://github.com/ithaca-lab-org/idp-infra/commit/c7193f54183a0949f9e0a0ae53fa9c385ef5ba6e))


### Bug Fixes

* **argocd:** create the root Application in a second release ([#9](https://github.com/ithaca-lab-org/idp-infra/issues/9)) ([6ed7947](https://github.com/ithaca-lab-org/idp-infra/commit/6ed794756a3888c7b249fa174f6415d1e9c28e38))
* **gke:** apply Opus review findings ([#4](https://github.com/ithaca-lab-org/idp-infra/issues/4)) ([1a7e27f](https://github.com/ithaca-lab-org/idp-infra/commit/1a7e27f7ee8cd682128116db72422a8b00170d02))
* **gke:** set spot on cluster node_config to avoid forced replacement ([#5](https://github.com/ithaca-lab-org/idp-infra/issues/5)) ([589ae33](https://github.com/ithaca-lab-org/idp-infra/commit/589ae33a1d03c8e666e927fa97b43a9d88a23cd4))
