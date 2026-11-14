# The core's own checks. `make lint` needs shellcheck and ruff on the PATH. `make test` needs Linux bash
# (the suite fails on macOS's bash 3.2): `make test-docker` runs it in the python:3.12 container instead.
# From an adopting project: make -C tools/autoloop/core lint test-docker
.PHONY: lint test test-docker

lint:
	shellcheck -x -S warning kickoff.sh telegram.sh lib/*.sh hooks/guard.sh service/install.sh
	ruff check .
	ruff format --check .

test:
	python3 -I -m unittest discover -s tests -p 'test_kickoff.py'

test-docker:
	docker run --rm -v "$(CURDIR)":/work -w /work python:3.12 python3 -I -m unittest discover -s tests -p 'test_kickoff.py'
