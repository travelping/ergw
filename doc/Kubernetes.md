## K8s NOTES

### Readiness Probe

An endpoint for k8s readiness probe is provided at the URL path `/status/ready` at the
endpoint configred in `http_api`.

The probe can be used from k8s like this:

    ports:
    - name: http-api-port
      containerPort: 8080
      hostPort: 8080
    
    readinessProbe:
      httpGet:
        path: /status/ready
        port: http-api-port
      initialDelaySeconds: 5
      periodSeconds: 5
