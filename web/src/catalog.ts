/** The product catalog, synced from the iOS app by `npm run sync-catalog`. */
import raw from './data/catalog.json';
import { AMAZON_TAG } from './config';

export interface CatalogItem {
  id: string;
  asin: string;
  name: string;
  brand: string;
  category: string;
  /** Real assembled dimensions in meters. Fit checks use these, never the mesh. */
  width: number;
  depth: number;
  height: number;
  /** Manufacturer color as linear-ish RGB in 0..1, used for the placeholder box. */
  color: [number, number, number];
  material: string;
  productURL: string;
}

export const CATALOG: CatalogItem[] = raw as CatalogItem[];

const byId = new Map(CATALOG.map((item) => [item.id, item]));
export const catalogItem = (id: string): CatalogItem | undefined => byId.get(id);

export const CATEGORY_LABELS: Record<string, string> = {
  bed: 'Beds',
  chair: 'Chairs',
  desk: 'Desks',
  dresser: 'Dressers',
  wardrobe: 'Wardrobes',
  nightstand: 'Nightstands',
  bookshelf: 'Bookshelves',
};

export const categories = (): string[] => [...new Set(CATALOG.map((i) => i.category))];

/** Outbound link. Adds the Associates tag only when a real one is configured. */
export function outboundURL(item: CatalogItem): string {
  if (!AMAZON_TAG) return item.productURL;
  const url = new URL(item.productURL);
  url.searchParams.set('tag', AMAZON_TAG);
  return url.toString();
}

export const modelURL = (item: CatalogItem) => `${import.meta.env.BASE_URL}models/${item.asin}.glb`;
export const thumbURL = (item: CatalogItem) => `${import.meta.env.BASE_URL}thumbs/${item.asin}.webp`;
