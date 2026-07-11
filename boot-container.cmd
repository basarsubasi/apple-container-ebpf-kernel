container run --cap-add ALL --name beemon-apple -it  --mount type=bind,source="$PWD/scripts",target=/scripts  alpine/curl  sh
