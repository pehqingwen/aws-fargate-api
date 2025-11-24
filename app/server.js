// app/server.js
import express from "express";
import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
import itemsRouter from "./routes/items.js";
import usersRouter from "./routes/users.js";

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

// Health check for ALB target group
app.get("/healthz", (_req, res) => res.json({ ok: true }));

// Low-level example route using DynamoDB (can keep or delete)
const ddb = new DynamoDBClient({
  region: process.env.AWS_REGION || "ap-southeast-1",
});

const TABLE_NAME = process.env.ITEMS_TABLE_NAME || "fargate-items";

app.post("/items/:id", async (req, res) => {
  try {
    await ddb.send(
      new PutItemCommand({
        TableName: TABLE_NAME,
        Item: { pk: { S: req.params.id } },
      })
    );
    res.json({ ok: true, id: req.params.id });
  } catch (err) {
    console.error("Error in /items/:id:", err);
    res.status(500).json({ error: "Failed to write item" });
  }
});

app.get("/", (_req, res) => res.send("welcome"));

app.get("/api/hello", (_req, res) => {
  res.json({ hello: "world" });
});

// extra health check
app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

// our new routers
app.use(itemsRouter);
app.use(usersRouter);

app.listen(PORT, "0.0.0.0", () => {
  console.log(`listening on ${PORT}`);
});
