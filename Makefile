.PHONY: demo demo-docker tf-validate-all tf-test-all clean

demo:
	./scripts/demo.sh

demo-docker:
	./scripts/demo.sh --docker

tf-validate-all:
	python3 scripts/verify_terraform.py

tf-test-all:
	python3 scripts/verify_terraform.py

clean:
	rm -f /tmp/advocate_assist_local_demo.db
