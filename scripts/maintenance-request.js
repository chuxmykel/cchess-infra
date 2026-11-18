// Run by the api container's own Node (scripts/maintenance.sh pipes it in):
// a request to cchess-be's /internal/maintenance, which answers only from
// inside the container. $METHOD is GET, PUT (announce it - $BODY's JSON
// gives the minutes until it begins) or DELETE (end it).
// Prints the answer, or fails with the status and the server's message.
fetch('http://127.0.0.1:3000/internal/maintenance', {
  method: process.env.METHOD || 'GET',
  headers: { 'content-type': 'application/json' },
  body: process.env.BODY || undefined,
}).then(
  async (res) => {
    const text = await res.text();
    if (!res.ok) {
      console.error(`${res.status} ${text}`);
      process.exit(1);
    }
    console.log(text);
  },
  (error) => {
    console.error(error.message);
    process.exit(1);
  },
);
