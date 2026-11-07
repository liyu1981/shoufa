import {
  createRootRoute,
  createRoute,
  createRouter,
  notFound,
  Outlet,
  redirect,
} from "@tanstack/react-router"
import HomePage from "@/pages/HomePage"
import SpacePage from "@/pages/SpacePage"
import { isValidSlug } from "@/lib/slug"

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

// Shared space links use /s/<slug>, but people also type /<slug> directly.
// `shoufad` answers those with a 301; this mirrors it for hosts that serve the
// SPA shell for every path (the vite dev server, a static preview), so the
// browser never lands on a route that does not exist. The real space route is
// two segments, so it can never collide with this one, and non-slug paths such
// as /s or /favicon.ico keep falling through to the not-found view.
const shorthandRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/$slug",
  beforeLoad: ({ params }) => {
    if (!isValidSlug(params.slug)) throw notFound()
    // `replace` keeps Back from bouncing straight back into the redirect.
    throw redirect({
      to: "/s/$slug",
      params: { slug: params.slug },
      replace: true,
    })
  },
  component: () => null,
})

function SpaceRoute() {
  const { slug } = spaceRoute.useParams()
  return <SpacePage slug={slug} />
}

const routeTree = rootRoute.addChildren([indexRoute, spaceRoute, shorthandRoute])

export const router = createRouter({ routeTree })

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router
  }
}
