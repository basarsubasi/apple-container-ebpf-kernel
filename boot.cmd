container run --name dev-container -it --cap-add ALL \
  --mount type=bind,source=/Users/basarsubasi/Projects,target=/Projects \
  --mount type=bind,source="$PWD/scripts",target=/scripts \
  alpine:latest sh -c '/scripts/setup-bpf-env.sh && /bin/sh'
