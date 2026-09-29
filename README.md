# Nestor Hermes

Nous Research Hermes LLM deployment via Ollama, integrated with Traefik (Let's Encrypt SSL) and exposed at `https://nestor-ai.biz-4-africa.com/hermes`.

## Architecture
- Ollama running in a dedicated Docker container (`nestor-hermes`)
- Traefik reverse proxy with automatic SSL certificate generation via Let's Encrypt (`myresolver`)
- Internal and proxy networks (`nestor_net`, `aegis_proxy`)
