import express from "express";
import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";

const app = express();
const PORT = process.env.PORT || 3000;

// Health check for ALB target group
app.get("/healthz", (req, res) => res.json({ ok: true }));

// Example route using DynamoDB (table created in TF as "fargate-items")
const ddb = new DynamoDBClient({ region: process.env.AWS_REGION || "ap-southeast-1" });
app.post("/items/:id", async (req, res) => {
  await ddb.send(new PutItemCommand({
    TableName: "fargate-items",
    Item: { pk: { S: req.params.id } }
  }));
  res.json({ ok: true, id: req.params.id });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`listening on ${PORT}`);
});
