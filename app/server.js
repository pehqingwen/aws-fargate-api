import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
const ddb = new DynamoDBClient({ region: process.env.AWS_REGION || "ap-southeast-1" });
app.post("/items/:id", async (req, res) => {
    await ddb.send(new PutItemCommand({ TableName: "fargate-items", Item: { pk: { S: req.params.id } } }));
    res.json({ ok: true });
});
