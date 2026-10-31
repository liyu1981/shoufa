import { createRootRoute, createRoute, createRouter, Outlet } from "@tanstack/react-router"
import HomePage from "@/pages/HomePage"
import SpacePage from "@/pages/SpacePage"

const rootRoute = createRootRoute({
  component: () => <Outlet />,
})

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: HomePage,
})

const spaceRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/s/$slug",
  component: SpaceRoute,
})

function SpaceRoute() {
  const { slug } = spaceRoute.useParams()
  return <SpacePage slug={slug} />
}

const routeTree = rootRoute.addChildren([indexRoute, spaceRoute])

export const router = createRouter({ routeTree })

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router
  }
}
