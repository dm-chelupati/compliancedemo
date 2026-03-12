const express = require('express');

const app = express();
app.use(express.json());

// In-memory todo storage
let todos = [
  { id: 1, title: 'Deploy via CI/CD pipeline', completed: true },
  { id: 2, title: 'Set up compliance monitoring', completed: false },
];
let deletedTodos = [];
let nextId = 3;

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// Get all active todos
app.get('/api/todos', (req, res) => {
  res.json(todos);
});

// Get deleted todos
app.get('/api/todos/deleted', (req, res) => {
  res.json(deletedTodos);
});

// Create todo
app.post('/api/todos', (req, res) => {
  const { title } = req.body;
  if (!title) return res.status(400).json({ error: 'title is required' });
  const todo = { id: nextId++, title, completed: false };
  todos.push(todo);
  res.status(201).json(todo);
});

// Update todo
app.patch('/api/todos/:id', (req, res) => {
  const todo = todos.find(t => t.id === parseInt(req.params.id));
  if (!todo) return res.status(404).json({ error: 'not found' });
  if (req.body.title !== undefined) todo.title = req.body.title;
  if (req.body.completed !== undefined) todo.completed = req.body.completed;
  res.json(todo);
});

// Soft-delete todo (moves to deleted list)
app.delete('/api/todos/:id', (req, res) => {
  const idx = todos.findIndex(t => t.id === parseInt(req.params.id));
  if (idx === -1) return res.status(404).json({ error: 'not found' });
  const [removed] = todos.splice(idx, 1);
  removed.deletedAt = new Date().toISOString();
  deletedTodos.push(removed);
  res.status(204).send();
});

// Restore a deleted todo
app.post('/api/todos/:id/restore', (req, res) => {
  const idx = deletedTodos.findIndex(t => t.id === parseInt(req.params.id));
  if (idx === -1) return res.status(404).json({ error: 'not found in deleted items' });
  const [restored] = deletedTodos.splice(idx, 1);
  delete restored.deletedAt;
  todos.push(restored);
  res.json(restored);
});

// Stats endpoint — counts of active and deleted todos
app.get('/api/todos/stats', (req, res) => {
  res.json({
    active: todos.filter(t => !t.completed).length,
    completed: todos.filter(t => t.completed).length,
    deleted: deletedTodos.length,
    total: todos.length + deletedTodos.length,
  });
});

const port = process.env.PORT || 8080;
app.listen(port, () => {
  console.log(`Todo API listening on port ${port}`);
});
