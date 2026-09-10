const { Redis } = require("@upstash/redis")
const fs = require("fs")

// Load .env.local
const envContent = fs.readFileSync(".env.local", "utf8")
const envVars = {}
envContent.split("\n").forEach(line => {
  if (line && !line.startsWith("#")) {
    const [key, ...valueParts] = line.split("=")
    if (key && valueParts.length > 0) {
      envVars[key.trim()] = valueParts.join("=").trim()
    }
  }
})

const redis = new Redis({
  url: envVars.UPSTASH_REDIS_REST_URL,
  token: envVars.UPSTASH_REDIS_REST_TOKEN,
})

async function test() {
  // Create test hash
  await redis.hset("test:hgetall", { name: "test", value: "123" })
  
  // Get as object
  const result = await redis.hgetall("test:hgetall")
  console.log("hgetall result:", result)
  console.log("Type:", typeof result)
  console.log("Is object:", result !== null && typeof result === "object" && !Array.isArray(result))
  
  // Cleanup
  await redis.del("test:hgetall")
}

test().catch(console.error)
