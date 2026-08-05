from flask import Flask, request, jsonify
import requests

app = Flask(__name__)
OLLAMA_URL = "http://host.docker.internal:11434/api/generate"

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})

@app.route("/alert", methods=["POST"])
def receive_alert():
    alert = request.get_json(force=True)
    prompt = f"Classify this security alert's severity (low/medium/high/critical) and suggest one remediation action:\n{alert}"
    try:
        resp = requests.post(OLLAMA_URL, json={"model": "llama3.1:8b", "prompt": prompt, "stream": False}, timeout=30)
        analysis = resp.json().get("response", "no response")
    except Exception as e:
        analysis = f"LLM call failed: {e}"
    return jsonify({"received": alert, "analysis": analysis})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
