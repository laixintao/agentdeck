.PHONY: test build ci-package release release-validate release-verify release-publish

test:
	./scripts/test.sh
	python3 -m unittest discover -s tests-release -v

build:
	./scripts/build-app.sh release

ci-package: test build
	./scripts/package-app.sh
	./scripts/verify-artifacts.sh "$${RELEASE_ARCH:-$$(uname -m)}"

release:
	python3 scripts/release.py $(if $(VERSION),--version $(VERSION),)

release-validate:
	python3 scripts/check-release.py --tag "$(RELEASE_TAG)"

release-verify: release-validate
	./scripts/verify-artifacts.sh arm64 x86_64

release-publish: release-validate
	./scripts/publish-release.sh
