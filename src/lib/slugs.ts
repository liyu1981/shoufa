// Primary school level vocabulary — ~200 adjectives × ~200 nouns = 40,000+ combos
// Fallback: single word + number (apple, apple1, apple2...)

const adjectives = [
  // colors
  "red", "blue", "green", "gold", "pink", "white", "black", "brown", "gray", "orange",
  // size
  "big", "small", "tiny", "tall", "long", "short", "wide", "thin", "fat", "deep",
  // feel
  "happy", "brave", "calm", "cool", "warm", "soft", "hard", "fast", "slow", "wild",
  // nature
  "fresh", "sunny", "rainy", "windy", "cloudy", "foggy", "starry", "icy", "dry", "wet",
  // quality
  "bright", "dark", "shiny", "dull", "smooth", "rough", "sweet", "sour", "loud", "quiet",
  // simple
  "old", "new", "good", "bad", "nice", "fine", "fun", "sad", "silly", "cute",
  // more
  "young", "quick", "lazy", "busy", "free", "safe", "rich", "poor", "clean", "dirty",
  // extra
  "round", "square", "flat", "full", "empty", "thick", "light", "heavy", "soft", "stiff",
  "warm", "cold", "hot", "cool", "mild", "raw", "ripe", "fresh", "stale", "raw",
  "loud", "mute", "sharp", "blunt", "tight", "loose", "near", "far", "late", "early",
  "pale", "bold", "mild", "vast", "huge", "deep", "high", "low", "rich", "rare",
]

const nouns = [
  // animals
  "cat", "dog", "fox", "owl", "bee", "ant", "cow", "pig", "hen", "duck",
  "bear", "wolf", "deer", "hawk", "clam", "crab", "frog", "toad", "slug", "worm",
  "fish", "seal", "mole", "hare", "lamb", "calf", "foal", "cub", "pup", "kit",
  // nature
  "sun", "moon", "star", "rain", "snow", "wind", "fire", "lake", "pond", "cave",
  "hill", "rock", "sand", "mud", "fog", "dawn", "dusk", "tide", "wave", "seed",
  "tree", "leaf", "root", "bark", "vine", "moss", "clay", "soil", "ash", "dew",
  // objects
  "ball", "bell", "book", "boot", "bowl", "barn", "gate", "kite", "drum", "bell",
  "cup", "pen", "pin", "pot", "box", "bag", "hat", "mat", "net", "key",
  "ring", "coin", "fork", "spoon", "bowl", "dish", "pan", "lid", "hook", "lock",
  // food
  "apple", "berry", "lemon", "melon", "peach", "plum", "bean", "corn", "rice", "nut",
  "bread", "soup", "cake", "pie", " jam", "sauce", "salt", "herb", "seed", "nut",
  // body
  "hand", "foot", "arm", "leg", "eye", "ear", "nose", "lips", "toe", "knee",
  "head", "face", "hair", "skin", "bone", "rib", "thumb", "palm", "heel", "jaw",
  // places
  "home", "path", "road", "farm", "dock", "port", "yard", "shed", "well", "pit",
  "wall", "door", "step", "seat", "desk", "shelf", "loft", "den", "shed", "tent",
  // misc
  "boy", "girl", "name", "song", "game", "play", "jump", "swim", "sing", "wish",
  "plan", "goal", "task", "note", "mark", "sign", "rule", "turn", "loop", "gap",
]

const allWords = [...adjectives, ...nouns]

function pick<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)]
}

/**
 * Generate a memorable slug.
 * Tries adjective-noun combos first, then word+number fallback.
 * @param isTaken - function to check if a slug is already in use
 */
export async function generateSlug(isTaken: (slug: string) => Promise<boolean>): Promise<string> {
  // Try 2-word combos: adjective-noun (40,000+ combos)
  for (let attempt = 0; attempt < 30; attempt++) {
    const adj = pick(adjectives)
    const noun = pick(nouns)
    const slug = `${adj}-${noun}`
    if (!(await isTaken(slug))) return slug
  }

  // Fallback: single word (apple, apple1, apple2...)
  const base = pick(allWords)
  if (!(await isTaken(base))) return base

  for (let i = 1; i <= 999; i++) {
    const slug = `${base}${i}`
    if (!(await isTaken(slug))) return slug
  }

  // Last resort: random short string
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  for (let attempt = 0; attempt < 100; attempt++) {
    let slug = ""
    for (let i = 0; i < 6; i++) slug += chars[Math.floor(Math.random() * chars.length)]
    if (!(await isTaken(slug))) return slug
  }

  throw new Error("Could not generate a unique slug")
}

/**
 * Validate custom slug format: lowercase alphanumeric with single hyphens
 */
export function isValidSlug(slug: string): boolean {
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug) && slug.length >= 2 && slug.length <= 32
}
