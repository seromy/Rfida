import os

from rfida_server import create_app

app = create_app()

if __name__ == "__main__":
    # 0.0.0.0 so the iPhone on the office Wi-Fi can reach the API. The Werkzeug
    # debugger allows remote code execution, so it is opt-in (FLASK_DEBUG=1).
    app.run(
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8123")),
        debug=os.environ.get("FLASK_DEBUG") == "1",
    )
