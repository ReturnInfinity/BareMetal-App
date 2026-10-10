#!/bin/bash
set -e

BOLD="\033[1m"
NORMAL="\033[0m"

if [ -f "./.prog_app" ]; then
	PROG_APP="$(cat ./.prog_app)"
else
	echo "Error: .prog_app not found. Run ./1-build.sh first."
	exit 1
fi

# setup.sh downloads the CLI; fetch it here too for checkouts set up before it did.
if [ ! -x "./bmcloud" ]; then
	curl -fsSL -o bmcloud https://baremetal.returninfinity.com/cli/bmcloud
	chmod +x bmcloud
fi

read -p "Upload baremetal.elf to the BareMetal Cloud for execution? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
	if ! ./bmcloud whoami > /dev/null; then
		echo -e "Run ${BOLD}./bmcloud login${NORMAL} (or ${BOLD}export BMC_API_KEY=YOURKEY${NORMAL}) first"
		exit 1
	fi

	NAME=$(basename "$PROG_APP" .app)
	NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9-' '-')
	IMAGE_ID=$(./bmcloud --json image upload "BareMetal-Firecracker/sys/baremetal.elf" --name "$NAME" --kind kernel | jq -r '.image.id')
	VM_ID=$(./bmcloud --json vm create "$NAME" --kernel "$IMAGE_ID" --ram 16 | jq -r '.vm.id')
	echo "Created VM $NAME ($VM_ID) from image $IMAGE_ID"
	echo -e "Check it with ${BOLD}./bmcloud vm show $VM_ID${NORMAL} and ${BOLD}./bmcloud vm console $VM_ID${NORMAL}"
fi
