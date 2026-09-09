import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  allowedDevOrigins: ["192.168.0.221"],
  output: "standalone",
};

export default nextConfig;
