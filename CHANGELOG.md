# Changelog

## [0.5.1](https://github.com/kinopshq/core/compare/v0.5.0...v0.5.1) (2026-11-28)


### Features

* platform UIs closed by default, note to add your IP ([#139](https://github.com/kinopshq/core/issues/139)) ([7573e0b](https://github.com/kinopshq/core/commit/7573e0b15401dc1b470765412a66cbe92a31523c))


### Bug fixes

* **try:** platform UIs answer the kind/minikube tunnel; re-run applies new settings ([#140](https://github.com/kinopshq/core/issues/140)) ([ee66037](https://github.com/kinopshq/core/commit/ee66037dcd758b135b0c31754805a921fcc39dcf))
* uninstall removes everything, local clone included ([#136](https://github.com/kinopshq/core/issues/136)) ([5146f45](https://github.com/kinopshq/core/commit/5146f4536108373f9159170d829efbb148dd245e))
* **uninstall:** show what goes away as a table (namespace, pods, PVCs, storage) ([#138](https://github.com/kinopshq/core/issues/138)) ([d5a0321](https://github.com/kinopshq/core/commit/d5a0321a41df87540613e5faea5d3381043bef68))

## [0.5.0](https://github.com/kinopshq/core/compare/v0.4.10...v0.5.0) (2026-11-28)


### ⚠ BREAKING CHANGES

* an existing fork that pulls this without setting global.platformAccess.allowedIPs gets 403 on ArgoCD, Grafana and Infisical. Add your IP (or [0.0.0.0/0] to keep them open) to cluster.yaml before updating.

### Features

* platform UIs only answer global.platformAccess.allowedIPs (Traefik ipAllowList) ([#134](https://github.com/kinopshq/core/issues/134)) ([0a85610](https://github.com/kinopshq/core/commit/0a85610a398c13f761cddb1d217a29181e112fff))

## [0.4.10](https://github.com/kinopshq/core/compare/v0.4.9...v0.4.10) (2026-11-27)


### Features

* **install:** detect Gateway API CRDs already installed by the distribution ([#131](https://github.com/kinopshq/core/issues/131)) ([6c02fe2](https://github.com/kinopshq/core/commit/6c02fe2b4bcba10cc1988e5c9b78bcdc225d5589))


### Bug fixes

* **install:** clear access warnings; cloud-provider-kind without its own Gateway API ([#128](https://github.com/kinopshq/core/issues/128)) ([a86c7b8](https://github.com/kinopshq/core/commit/a86c7b8bb941c8cccc6a60b40224537a9fb1ce26))

## [0.4.9](https://github.com/kinopshq/core/compare/v0.4.8...v0.4.9) (2026-11-27)


### Dependencies

* **deps:** update helm release argo-cd to v10.20.0 ([#109](https://github.com/kinopshq/core/issues/109)) ([ec3ad44](https://github.com/kinopshq/core/commit/ec3ad446d2007ac65fb96fc4cea4fd8fca87c369))
* **deps:** update helm release cilium to v1.20.5 ([#103](https://github.com/kinopshq/core/issues/103)) ([2a6b446](https://github.com/kinopshq/core/commit/2a6b446bedde488a89b99350c3d63b1af004a19e))
* **deps:** update helm release cloudnative-pg to v0.29.2 ([#104](https://github.com/kinopshq/core/issues/104)) ([750af5b](https://github.com/kinopshq/core/commit/750af5b14e66279dc9e50033046b721c02f85c4c))
* **deps:** update helm release external-dns to v1.24.0 ([#110](https://github.com/kinopshq/core/issues/110)) ([02da904](https://github.com/kinopshq/core/commit/02da904dbf9c97742912fd929c806f2b6b914ef4))
* **deps:** update helm release external-secrets to v2.15.0 ([#111](https://github.com/kinopshq/core/issues/111)) ([b508d8b](https://github.com/kinopshq/core/commit/b508d8b981ea9afbe126593c508a439fa6abf21b))
* **deps:** update helm release infisical-standalone to v1.12.6 ([#105](https://github.com/kinopshq/core/issues/105)) ([22439bc](https://github.com/kinopshq/core/commit/22439bc5f3f082295e36ffc07313ab7b52d4d9ac))
* **deps:** update helm release kube-prometheus-stack to v94 ([#118](https://github.com/kinopshq/core/issues/118)) ([0ec4ab9](https://github.com/kinopshq/core/commit/0ec4ab9a935d673247dfe51fb7620a29c05d4815))
* **deps:** update helm release reloader to v2.2.21 ([#106](https://github.com/kinopshq/core/issues/106)) ([cdd6e1b](https://github.com/kinopshq/core/commit/cdd6e1b349193ca97ac18ecf5d767fd1b2523e54))
* **deps:** update helm release seaweedfs to v4.55.0 ([#112](https://github.com/kinopshq/core/issues/112)) ([2ebf280](https://github.com/kinopshq/core/commit/2ebf2805c9ec2e841efd9d96ad1f943ce16ca797))
* **deps:** update helm release valkey to v1 ([#120](https://github.com/kinopshq/core/issues/120)) ([e11dbac](https://github.com/kinopshq/core/commit/e11dbacd7279ae50b63530d257626d404e8920bf))

## [0.4.8](https://github.com/kinopshq/core/compare/v0.4.7...v0.4.8) (2026-11-26)


### Bug fixes

* **renovate:** chart and image updates as deps(...) so they trigger a release ([#100](https://github.com/kinopshq/core/issues/100)) ([a91d81d](https://github.com/kinopshq/core/commit/a91d81d8fea224297dd4c3399f6605d5b219deda))
* **traefik:** Gateway API CRDs v1.7.0 for Kubernetes 1.37 ([#123](https://github.com/kinopshq/core/issues/123)) ([d08da58](https://github.com/kinopshq/core/commit/d08da5817422bda6b08c04949613edcfb1d77491))

## [0.4.7](https://github.com/kinopshq/core/compare/v0.4.6...v0.4.7) (2026-11-26)


### Bug fixes

* kinops folder names in try.sh/install.sh, AI Platform and Enterprise marked Coming soon in README ([#94](https://github.com/kinopshq/core/issues/94)) ([e9077f7](https://github.com/kinopshq/core/commit/e9077f7a834e43ba273ed7de64ded331e69b7400))
* kinops instead of kien-stack in external-dns owner id, Infisical org, release-please package ([#96](https://github.com/kinopshq/core/issues/96)) ([161cb79](https://github.com/kinopshq/core/commit/161cb7958861177ec2384c314c29291a83a7c308))

## [0.4.6](https://github.com/kinopshq/core/compare/v0.4.5...v0.4.6) (2026-11-26)


### Features

* **backup:** Postgres backups to in-cluster S3 (SeaweedFS) with the Barman Cloud plugin ([#86](https://github.com/kinopshq/core/issues/86)) ([d3cb99d](https://github.com/kinopshq/core/commit/d3cb99dec5608b1216bdddd454ee16432b92f566))
* **monitoring:** daily VictoriaMetrics backup to SeaweedFS S3 (vmbackup CronJob) ([#91](https://github.com/kinopshq/core/issues/91)) ([b9cf825](https://github.com/kinopshq/core/commit/b9cf825d4ea413e7958e32e1fa10feb2b64745ca))
* **monitoring:** Grafana dashboards sorted in folders ([#89](https://github.com/kinopshq/core/issues/89)) ([5727e89](https://github.com/kinopshq/core/commit/5727e8970e9a5f2b2a123ac57266be268d1af34b))


### Documentation

* **argocd:** progressive sync stages and dependencies (mermaid) ([#88](https://github.com/kinopshq/core/issues/88)) ([2d13ce9](https://github.com/kinopshq/core/commit/2d13ce9e576168b52fd0ecd88585905db159b826))
* **monitoring:** README with VictoriaMetrics backup and restore steps ([#92](https://github.com/kinopshq/core/issues/92)) ([2bc43d4](https://github.com/kinopshq/core/commit/2bc43d411291872628de5a4e69f627253048de5b))
* **readme:** packs and features as on the shop (S3, SSO in AI Platform, resilience in Enterprise) ([#90](https://github.com/kinopshq/core/issues/90)) ([734065a](https://github.com/kinopshq/core/commit/734065a9923bc870b34a2d2732f24d0cef79ba6d))

## [0.4.5](https://github.com/kinopshq/core/compare/v0.4.4...v0.4.5) (2026-11-24)


### Bug fixes

* **install:** restore the community pack name (reverted by [#80](https://github.com/kinopshq/core/issues/80)) ([#83](https://github.com/kinopshq/core/issues/83)) ([f3e9e75](https://github.com/kinopshq/core/commit/f3e9e7537cca010c77d7446ce94f211ea0948aa6))

## [0.4.4](https://github.com/kinopshq/core/compare/v0.4.3...v0.4.4) (2026-11-24)


### Bug fixes

* **install:** show the new pack name (Community, AI Platform, Enterprise) ([#81](https://github.com/kinopshq/core/issues/81)) ([eaf4658](https://github.com/kinopshq/core/commit/eaf465852c5edaf1f05e0bd74a2b8d67b6e8f449))

## [0.4.3](https://github.com/kien-stack/core/compare/v0.4.2...v0.4.3) (2026-11-24)


### Documentation

* install from a private repo ([#77](https://github.com/kien-stack/core/issues/77)) ([babd26f](https://github.com/kien-stack/core/commit/babd26fade1310e56368f2fd5385a07bd4b917f8))
* rebrand to kinops, rename packs (Community, AI Platform, Enterprise) ([#79](https://github.com/kien-stack/core/issues/79)) ([26dfd6d](https://github.com/kien-stack/core/commit/26dfd6d64e3a4b27329ea384f765c09a4089893f))

## [0.4.2](https://github.com/kien-stack/essential/compare/v0.4.1...v0.4.2) (2026-11-23)


### Features

* **install:** Warnings and Deploy sections, /etc/hosts hint without a domain ([#74](https://github.com/kien-stack/essential/issues/74)) ([fcb9aac](https://github.com/kien-stack/essential/commit/fcb9aac9a5b1e05cffb07d606555661c1e9b97b3))
* ordered deploy (progressive sync + DB first) ([#76](https://github.com/kien-stack/essential/issues/76)) ([dcfa419](https://github.com/kien-stack/essential/commit/dcfa4198847b31558c6badab66cc226dbf86799b))

## [0.4.1](https://github.com/kien-stack/essential/compare/v0.4.0...v0.4.1) (2026-11-23)


### Features

* **install:** friendlier output, logins only when ready, never print passwords ([#72](https://github.com/kien-stack/essential/issues/72)) ([0379f53](https://github.com/kien-stack/essential/commit/0379f536890b46c4a7d9f956d349f191a24d876c))

## [0.4.0](https://github.com/kien-stack/essential/compare/v0.3.12...v0.4.0) (2026-11-23)


### ⚠ BREAKING CHANGES

* **apps:** remove the hello sample app, add examples/postgres-api + BOOTSTRAP-APP guide ([#64](https://github.com/kien-stack/essential/issues/64))

### Features

* **apps:** remove the hello sample app, add examples/postgres-api + BOOTSTRAP-APP guide ([#64](https://github.com/kien-stack/essential/issues/64)) ([bc1e9bc](https://github.com/kien-stack/essential/commit/bc1e9bc157a17360295ad55e9fa59b647d212824))
* **install:** access box with URL/user/password commands per enabled brick ([#60](https://github.com/kien-stack/essential/issues/60)) ([53c2685](https://github.com/kien-stack/essential/commit/53c2685db1cb14f39d4660c5ce94bd150ae4f2b3))
* **installer:** single install.sh (configure + install) ([#69](https://github.com/kien-stack/essential/issues/69)) ([acdeec1](https://github.com/kien-stack/essential/commit/acdeec1625e6ca08aa998a075da99ce621c8113f))
* **monitoring:** add monitoring brick, planned Pro pack in docs ([#62](https://github.com/kien-stack/essential/issues/62)) ([fffbae9](https://github.com/kien-stack/essential/commit/fffbae9ead1114d5401e1158b351ce139cd42a5c))
* **monitoring:** Grafana home dashboard = Kubernetes / Compute Resources / Cluster ([#66](https://github.com/kien-stack/essential/issues/66)) ([1aeae6a](https://github.com/kien-stack/essential/commit/1aeae6a4c092d999b9be352a595e22d4288e8488))
* **monitoring:** VictoriaLogs explorer dashboard (25747) ([#68](https://github.com/kien-stack/essential/issues/68)) ([2023b30](https://github.com/kien-stack/essential/commit/2023b30336d67c654d8d5d4962312f33b228b34b))

## [0.3.12](https://github.com/kien-stack/essential/compare/v0.3.11...v0.3.12) (2026-11-22)


### Features

* **infisical:** turnkey Infisical + External Secrets (project kubernetes, stores infisical-&lt;env&gt;) ([#58](https://github.com/kien-stack/essential/issues/58)) ([799235f](https://github.com/kien-stack/essential/commit/799235f274dc435162c780a8959ce42d6f6e1cd4))

## [0.3.11](https://github.com/kien-stack/essential/compare/v0.3.10...v0.3.11) (2026-11-19)


### Bug fixes

* **cert-manager:** rename CA to cluster-ca like full ([#56](https://github.com/kien-stack/essential/issues/56)) ([ccc090c](https://github.com/kien-stack/essential/commit/ccc090cacaaac0208dcb8b1b598efa4ac3ffb2d3))

## [0.3.10](https://github.com/kien-stack/essential/compare/v0.3.9...v0.3.10) (2026-11-19)


### Features

* **platform:** default-deny ingress NetworkPolicies ([#54](https://github.com/kien-stack/essential/issues/54)) ([6266ce6](https://github.com/kien-stack/essential/commit/6266ce67d0da6b9ae18b76c8fd5ecb34b07041a7))


### Bug fixes

* **install:** resolve *.&lt;domain&gt; to Traefik inside the cluster ([#53](https://github.com/kien-stack/essential/issues/53)) ([9fd188f](https://github.com/kien-stack/essential/commit/9fd188fe055f67659562a6f7e227dc92f6cf4f53))

## [0.3.9](https://github.com/kien-stack/essential/compare/v0.3.8...v0.3.9) (2026-11-16)


### Bug fixes

* **try:** uninstall really removes the demo ([#49](https://github.com/kien-stack/essential/issues/49)) ([02e5792](https://github.com/kien-stack/essential/commit/02e57927d7512abda5eff3cc23de6aa4444955b0))

## [0.3.8](https://github.com/kien-stack/essential/compare/v0.3.7...v0.3.8) (2026-11-16)


### Bug fixes

* **try:** skip the Git checks in demo mode ([#47](https://github.com/kien-stack/essential/issues/47)) ([846639b](https://github.com/kien-stack/essential/commit/846639bf5c6e7899222d18bbdc13655b3e714ea2))

## [0.3.7](https://github.com/kien-stack/essential/compare/v0.3.6...v0.3.7) (2026-11-15)


### Features

* **examples:** app-template examples per workload type ([#42](https://github.com/kien-stack/essential/issues/42)) ([6d6b638](https://github.com/kien-stack/essential/commit/6d6b6385c70d4c155bba9c2a56ebf220cffbd06a))


### Documentation

* shorter, simpler README ([#45](https://github.com/kien-stack/essential/issues/45)) ([64563d5](https://github.com/kien-stack/essential/commit/64563d5a8076473e30b868c4626787c1043c575a))

## [0.3.6](https://github.com/kien-stack/essential/compare/v0.3.5...v0.3.6) (2026-11-12)


### Features

* **install:** wait until every app is ready, show progress ([#40](https://github.com/kien-stack/essential/issues/40)) ([7b34f52](https://github.com/kien-stack/essential/commit/7b34f521c60011537e4bab84d34b00257a8caf8b))

## [0.3.5](https://github.com/kien-stack/essential/compare/v0.3.4...v0.3.5) (2026-11-11)


### Bug fixes

* **install:** refuse to install when cluster.yaml / argocd / helm changes are not pushed ([#35](https://github.com/kien-stack/essential/issues/35)) ([3a14b16](https://github.com/kien-stack/essential/commit/3a14b163c8813291e7d2391837bfebb8aa47cb94))

## [0.3.4](https://github.com/kien-stack/essential/compare/v0.3.3...v0.3.4) (2026-11-10)


### Features

* host try.sh and install.sh in the repo (raw.githubusercontent.com) ([#30](https://github.com/kien-stack/essential/issues/30)) ([4337946](https://github.com/kien-stack/essential/commit/43379467dcbdf503cbd747618ecdda79bbccf747))

## [0.3.3](https://github.com/kien-stack/essential/compare/v0.3.2...v0.3.3) (2026-11-09)


### Features

* generate passwords with the External Secrets ClusterGenerator ([#27](https://github.com/kien-stack/essential/issues/27)) ([5c48b9c](https://github.com/kien-stack/essential/commit/5c48b9c32bfcfffcba6fd134cd805fdf72f1992a))

## [0.3.2](https://github.com/dedsxc/kien-stack-essential/compare/v0.3.1...v0.3.2) (2026-11-09)


### Bug fixes

* **traefik:** externalTrafficPolicy Local to keep client IP ([#20](https://github.com/dedsxc/kien-stack-essential/issues/20)) ([c15ecae](https://github.com/dedsxc/kien-stack-essential/commit/c15ecae4095c2f159bfcd4c3cda419ae00c94b7d))

## [0.3.1](https://github.com/dedsxc/kien-stack-essential/compare/v0.3.0...v0.3.1) (2026-11-09)


### Bug fixes

* **install:** bootstrap ArgoCD without HTTPRoute ([#19](https://github.com/dedsxc/kien-stack-essential/issues/19)) ([60ee916](https://github.com/dedsxc/kien-stack-essential/commit/60ee9161a728fa0d255b94d61c893e0ee182be0a))
* **install:** make install.sh executable ([#17](https://github.com/dedsxc/kien-stack-essential/issues/17)) ([f643792](https://github.com/dedsxc/kien-stack-essential/commit/f643792bedaa0909c598c6268fb7afdc92bfca55))

## [0.3.0](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.4...v0.3.0) (2026-11-09)


### ⚠ BREAKING CHANGES

* expose apps with Gateway API (HTTPRoute) instead of Ingress ([#15](https://github.com/dedsxc/kien-stack-essential/issues/15))

### Features

* expose apps with Gateway API (HTTPRoute) instead of Ingress ([#15](https://github.com/dedsxc/kien-stack-essential/issues/15)) ([db040f7](https://github.com/dedsxc/kien-stack-essential/commit/db040f7309994c47ea6e763bcb5ae75f46108004))

## [0.2.4](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.3...v0.2.4) (2026-11-08)


### Bug fixes

* values carry no global defaults, cluster.yaml provides them ([#13](https://github.com/dedsxc/kien-stack-essential/issues/13)) ([32817b7](https://github.com/dedsxc/kien-stack-essential/commit/32817b74df56d10d081f81a6e969de8782bfe157))

## [0.2.3](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.2...v0.2.3) (2026-11-08)


### Bug fixes

* **install:** retry chart downloads, silence tr broken pipe ([#10](https://github.com/dedsxc/kien-stack-essential/issues/10)) ([ee4b9c5](https://github.com/dedsxc/kien-stack-essential/commit/ee4b9c508b254df5e472f10cbb5800940657aa77))

## [0.2.2](https://github.com/dedsxc/kien-stack-essential/compare/v0.2.1...v0.2.2) (2026-11-08)


### Features

* app Postgres via cnpg-cluster chart, password ClusterGenerator, Reloader component ([#4](https://github.com/dedsxc/kien-stack-essential/issues/4)) ([a0af69f](https://github.com/dedsxc/kien-stack-essential/commit/a0af69f0ffc5ccba4bd1f889f99904181dd23b87))
