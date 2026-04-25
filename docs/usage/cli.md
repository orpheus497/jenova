# Headless & CLI Usage

While the canonical interactive experience is via `jvim`, Jenova also supports headless and scripted workflows.

## The Backend Supervisor (`jenova-ca`)
You can start the cognitive backend without the editor. This is useful for remote setups or if you want to use the API directly.

```sh
# Start the backend in the background
bin/jenova-ca --daemon

# Check status
bin/jenova-ca status

# Stop the backend
bin/jenova-ca stop
```

## Scripted Workflows
You can use `bin/jenova` to interact with the backend from the terminal. The agent logic is shared with `jvim` but can be invoked headlessly.

### Usage
```sh
# Run a one-shot query against the local backend (planned feature)
bin/jenova --one-shot "Summarize this file"

# Check the environment and backend connectivity
bin/jenova --check
```

## API Access
The Jenova Intelligence Proxy provides an OpenAI-compatible endpoint at `http://localhost:8080/v1/chat/completions`. You can use any standard client (like `curl` or an OpenAI SDK) to talk to your local model.

Example:
```sh
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "jenova",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```
