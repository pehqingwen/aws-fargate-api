// app/routes/items.js
import express from "express";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  ScanCommand,
  PutCommand,
} from "@aws-sdk/lib-dynamodb";

const router = express.Router();

const TABLE_NAME = process.env.ITEMS_TABLE_NAME;
if (!TABLE_NAME) {
  console.warn("ITEMS_TABLE_NAME is not set – /items routes will fail");
}

// v3 client; region comes from env / ECS
const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);

// GET /items – list all items
router.get("/items", async (_req, res) => {
  try {
    const data = await docClient.send(
      new ScanCommand({ TableName: TABLE_NAME })
    );
    res.json(data.Items ?? []);
  } catch (err) {
    console.error("Error scanning items table:", err);
    res.status(500).json({ error: "Failed to fetch items" });
  }
});

// POST /items – create a new item
router.post("/items", async (req, res) => {
  try {
    const id =
      globalThis.crypto?.randomUUID?.() ?? Date.now().toString();

    const item = {
      id,
      ...req.body,
    };

    await docClient.send(
      new PutCommand({
        TableName: TABLE_NAME,
        Item: item,
      })
    );

    res.status(201).json(item);
  } catch (err) {
    console.error("Error creating item:", err);
    res.status(500).json({ error: "Failed to create item" });
  }
});

export default router;
