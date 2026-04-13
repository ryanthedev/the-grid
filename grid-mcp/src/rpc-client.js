import { createConnection } from "net";
import { randomUUID } from "crypto";

class RPCError extends Error {
  constructor(type, message) {
    super(message);
    this.name = "RPCError";
    this.type = type;
  }
}

export class RPCClient {
  constructor(socketPath = null, timeout = 30000) {
    this.socketPath =
      socketPath ||
      process.env.GRID_SOCKET ||
      "/tmp/grid-server.sock";
    this.timeout = timeout;
  }

  async call(method, params = {}) {
    const requestId = randomUUID();
    const envelope = {
      type: "request",
      request: {
        id: requestId,
        method,
        params,
      },
    };

    const jsonData = JSON.stringify(envelope) + "\n";

    return new Promise((resolve, reject) => {
      const socket = createConnection(this.socketPath, () => {
        socket.write(jsonData, (err) => {
          if (err) {
            socket.destroy();
            reject(
              new RPCError("WRITE_FAILED", `Failed to write to socket: ${err.message}`)
            );
            return;
          }

          let buffer = "";

          socket.on("data", (chunk) => {
            buffer += chunk.toString();
            const lines = buffer.split("\n");

            for (let i = 0; i < lines.length - 1; i++) {
              const line = lines[i];
              if (line.length === 0) continue;

              try {
                const response = JSON.parse(line);

                if (response.type !== "response") {
                  socket.destroy();
                  reject(
                    new RPCError(
                      "INVALID_RESPONSE",
                      "Response type is not 'response'"
                    )
                  );
                  return;
                }

                const respObj = response.response;
                if (!respObj) {
                  socket.destroy();
                  reject(
                    new RPCError(
                      "INVALID_RESPONSE",
                      "Missing response object"
                    )
                  );
                  return;
                }

                if (respObj.error) {
                  socket.destroy();
                  const code = respObj.error.code || -1;
                  const message = respObj.error.message || "Unknown error";
                  reject(
                    new RPCError("SERVER_ERROR", `[${code}] ${message}`)
                  );
                  return;
                }

                socket.destroy();
                resolve(respObj.result || {});
              } catch (e) {
                socket.destroy();
                reject(
                  new RPCError(
                    "INVALID_RESPONSE",
                    `Failed to parse response: ${e.message}`
                  )
                );
              }
            }

            buffer = lines[lines.length - 1];
          });

          socket.on("error", (err) => {
            reject(
              new RPCError(
                "CONNECTION_FAILED",
                `Cannot connect to ${this.socketPath}: ${err.message}`
              )
            );
          });

          socket.on("end", () => {
            reject(
              new RPCError("READ_FAILED", "Connection closed by server")
            );
          });
        });
      });

      socket.on("error", (err) => {
        reject(
          new RPCError(
            "CONNECTION_FAILED",
            `Cannot connect to ${this.socketPath}: ${err.message}`
          )
        );
      });

      const timeoutHandle = setTimeout(() => {
        socket.destroy();
        reject(new RPCError("TIMEOUT", "Request timed out"));
      }, this.timeout);

      socket.on("close", () => {
        clearTimeout(timeoutHandle);
      });
    });
  }
}
