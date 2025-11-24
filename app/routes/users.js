// app/routes/users.js
import express from "express";
import pool from "../db.js";

const router = express.Router();

// GET /users
router.get("/users", async (_req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, email FROM users ORDER BY id"
    );
    res.json(rows);
  } catch (err) {
    console.error("Error fetching users:", err);
    res.status(500).json({ error: "Failed to fetch users" });
  }
});

// POST /users
router.post("/users", async (req, res) => {
  const { name, email } = req.body;
  if (!name || !email) {
    return res
      .status(400)
      .json({ error: "name and email are required" });
  }

  try {
    const { rows } = await pool.query(
      "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id, name, email",
      [name, email]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    console.error("Error creating user:", err);
    res.status(500).json({ error: "Failed to create user" });
  }
});

export default router;
