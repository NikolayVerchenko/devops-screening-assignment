.PHONY: structure validate

structure:
	./scripts/validate.sh --structure-only

validate:
	./scripts/validate.sh
