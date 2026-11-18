# Minimal OKD derivative of the published fullsend runner image.
#
# Why a derivative instead of the stock image:
#   * the stock image pins OpenShell 0.1.4, while the OKD gateway runs
#     0.1.6-rhaiv.4; a client/server skew is not something we want to debug
#     during first bring-up
#   * we inject the `fullsend` binary built from this checkout so the CLI we
#     validated against the harness is the CLI that runs in-cluster
#
# Everything else (gh, jq, python3+jsonschema, git, gitleaks, pre-commit,
# gitlint, Go) comes from the stock runner image.
FROM ghcr.io/fullsend-ai/fullsend-runner:latest

USER 0

COPY openshell /usr/local/bin/openshell
COPY fullsend  /usr/local/bin/fullsend

# The patched agents harness (OpenCode runtime, local-inference profile,
# local agent registration). Baked in so the Job has no git dependency for
# its own configuration; only the *target* repo is cloned at run time.
COPY agents-okd/ /harness/

RUN chmod 0755 /usr/local/bin/openshell /usr/local/bin/fullsend \
 && chmod -R a+rX /harness \
 && /usr/local/bin/openshell --version \
 && /usr/local/bin/fullsend --version

# GitHub App installation tokens are minted in-cluster with an RS256 JWT
# (scripts/mint-app-token.sh). The stock image has no openssl CLI and no
# python cryptography module, so install the CLI.
RUN dnf -y install openssl && dnf clean all && openssl version

# OpenShift runs this image as an arbitrary UID unless USER is set, so HOME
# must be writable. `fullsend run` writes its OpenShell gateway credentials
# under $HOME/.config/openshell and its run output under /tmp/fullsend.
ENV HOME=/work
RUN mkdir -p /work/.config && chmod -R 0777 /work

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/fullsend"]
CMD ["--help"]
