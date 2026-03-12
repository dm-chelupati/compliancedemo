const express = require('express');

const app = express();
app.use(express.json());

// Valid priority levels
const PRIORITIES = ['low', 'medium', 'high'];

// In-memory todo storage
let todos = [
  { id: 1, title: 'Deploy via CI/CD pipeline', completed: true, priority: 'high', dueDate: null, createdAt: '2026-03-11T00:00:00Z' },
  { id: 2, title: 'Set up compliance monitoring', completed: false, priority: 'medium', dueDate: '2026-03-15T00:00:00Z', createdAt: '2026-03-11T00:00:00Z' },
];
let deletedTodos = [];
let nextId = 3;

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', version: '1.2.0', timestamp: new Date().toISOString() });
});

// Get all active todos (supports ?priority=high and ?completed=true filters)
app.get('/api/todos', (req, res) => {
  let result = todos;
  if (req.query.priority) {
    result = result.filter(t => t.priority === req.query.priority);
  }
  if (req.query.completed !== undefined) {
    const completed = req.query.completed === 'true';
    result = result.filter(t => t.completed === completed);
  }
  res.json(result);
});

// Search todos by title (case-insensitive substring match)
app.get('/api/todos/search', (req, res) => {
  const q = (req.query.q || '').toLowerCase();
  if (!q) return res.status(400).json({ error: 'query parameter "q" is required' });
  let result = todos.filter(t => t.title.toLowerCase().includes(q));
  if (req.query.priority) {
    result = result.filter(t => t.priority === req.query.priority);
  }
  res.json(result);
});

// Get deleted todos
app.get('/api/todos/deleted', (req, res) => {
  res.json(deletedTodos);
});

// Create todo (accepts optional priority and dueDate)
app.post('/api/todos', (req, res) => {
  const { title, priority, dueDate } = req.body;
  if (!title) return res.status(400).json({ error: 'title is required' });
  const todoPriority = priority || 'medium';
  if (!PRIORITIES.includes(todoPriority)) {
    return res.status(400).json({ error: `priority must be one of: ${PRIORITIES.join(', ')}` });
  }
  if (dueDate && isNaN(Date.parse(dueDate))) {
    return res.status(400).json({ error: 'dueDate must be a valid ISO date string' });
  }
  const todo = {
    id: nextId++,
    title,
    completed: false,
    priority: todoPriority,
    dueDate: dueDate || null,
    createdAt: new Date().toISOString(),
  };
  todos.push(todo);
  res.status(201).json(todo);
});

// Update todo
app.patch('/api/todos/:id', (req, res) => {
  const todo = todos.find(t => t.id === parseInt(req.params.id));
  if (!todo) return res.status(404).json({ error: 'not found' });
  if (req.body.title !== undefined) todo.title = req.body.title;
  if (req.body.completed !== undefined) todo.completed = req.body.completed;
  if (req.body.priority !== undefined) {
    if (!PRIORITIES.includes(req.body.priority)) {
      return res.status(400).json({ error: `priority must be one of: ${PRIORITIES.join(', ')}` });
    }
    todo.priority = req.body.priority;
  }
  if (req.body.dueDate !== undefined) {
    if (req.body.dueDate !== null && isNaN(Date.parse(req.body.dueDate))) {
      return res.status(400).json({ error: 'dueDate must be a valid ISO date string or null' });
    }
    todo.dueDate = req.body.dueDate;
  }
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

// Get todos due within the next N hours (default 24)
app.get('/api/todos/due-soon', (req, res) => {
  const hours = parseInt(req.query.hours) || 24;
  const cutoff = new Date(Date.now() + hours * 60 * 60 * 1000);
  const dueSoon = todos.filter(t => !t.completed && t.dueDate && new Date(t.dueDate) <= cutoff);
  res.json(dueSoon);
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
