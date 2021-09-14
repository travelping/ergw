## Docker Images
Docker images are build by [GitHub Actions](.github/workflows/docker.yaml) and pushed to [hub.docker.com](https://hub.docker.com/r/ergw/ergw-c-node/tags),
and by gitlab.com and pushed to [quay.io](https://quay.io/repository/travelping/ergw-c-node?tab=tags).

### Building Docker Image
An erGW Docker image can be get from [quay.io](https://quay.io/repository/travelping/ergw-c-node?tab=tags).  
To create a new image based on `ergw-c-node` from `quay.io`, run the second command:

```sh
$ docker run -t -i --rm quay.io/travelping/ergw-c-node:2.4.2 -- /bin/sh
/ # cd opt
/opt # ls
ergw-c-node
```
