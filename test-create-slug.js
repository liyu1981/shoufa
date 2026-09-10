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
  const slug = "test-" + Date.now()
  const key = `slug:${slug}`
  
  console.log("Creating slug:", slug)
  console.log("Key:", key)
  
  // Simulate createSlug
  const meta = { slug, createdAt: Date.now() }
  console.log("Meta:", meta)
  
  try {
    await redis.hset(key, meta)
    console.log("hset OK")
    
    await redis.expire(key, 3600)
    console.log("expire OK")
    
    // Verify
    const exists = await redis.exists(key)
    console.log("exists:", exists)
    
    const hgetall = await redis.hgetall(key)
    console.log("hgetall:", hgetall)
    
    // Cleanup
    await redis.del(key)
    console.log("Cleanup OK")
    
    console.log("\n✅ Test passed!")
  } catch (error) {
    console.error("❌ Error:", error.message)
  }
}

test()
