# SEO Plan for Haus of Sutra

## Current State Analysis

**Domain:** www.hausofsutra.com  
**Type:** Single-page static site (GitHub Pages)  
**Content:** Instagram feed carousel for Seattle/Tacoma artist collective

### What's Already in Place ✅
- Page title: "Haus of Sutra"
- Meta description
- Open Graph tags for social sharing
- Twitter Card meta tags
- Mobile-responsive design

### Current Gaps ❌
- No semantic HTML structure (h1, article, nav, footer)
- No structured data (Schema.org)
- No sitemap.xml
- No robots.txt
- No favicon
- No canonical URL
- Content is dynamically loaded (not crawlable by search engines)

---

## Priority 1: Technical SEO Foundation

### 1.1 Add Semantic HTML Structure
```html
<header> - Profile card
<main> - Carousel content  
<nav> - Controls
<footer> - Credits/links
<h1> - "Haus of Sutra" (currently missing!)
```

### 1.2 Add Essential Files

| File | Purpose |
|------|---------|
| `robots.txt` | Allow search engine crawling |
| `sitemap.xml` | Help search engines discover pages |
| `favicon.ico` | Browser tab icon + brand recognition |

### 1.3 Add Canonical URL
```html
<link rel="canonical" href="https://www.hausofsutra.com/">
```

### 1.4 Improve OG Image
Current image is small (profile pic). Create a 1200x630px branded OG image for better social previews.

---

## Priority 2: Content Optimization

### 2.1 Expand Meta Description
**Current:** "Seattle/Tacoma Artist Collective"

**Recommended:** "Haus of Sutra - Seattle & Tacoma's premier LGBTQ+ artist collective featuring drag performers, entertainers, and creatives. Follow our journey."

### 2.2 Add Visible H1 Tag
Search engines prioritize the `<h1>` tag. Add a visible or screen-reader accessible heading:
```html
<h1 class="visually-hidden">Haus of Sutra - Seattle Tacoma Artist Collective</h1>
```

### 2.3 Add Static Content for Crawlers
Since content loads via JavaScript, search engines may not see it. Options:
- Add a `<noscript>` fallback with key info
- Pre-render member names and links
- Add an "About" section with text content

---

## Priority 3: Structured Data (Schema.org)

Add JSON-LD structured data for rich search results:

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "PerformingGroup",
  "name": "Haus of Sutra",
  "description": "Seattle/Tacoma LGBTQ+ Artist Collective",
  "url": "https://www.hausofsutra.com",
  "sameAs": [
    "https://www.instagram.com/hausofsutra"
  ],
  "location": {
    "@type": "Place",
    "name": "Seattle-Tacoma, Washington"
  }
}
</script>
```

---

## Priority 4: Local SEO

Since you're a Seattle/Tacoma collective:

### 4.1 Google Business Profile
- Create a Google Business Profile (free)
- Category: "Performing Arts Group" or "Entertainment Agency"
- Add photos, events, and link to website

### 4.2 Local Keywords
Target these in content:
- "Seattle drag performers"
- "Tacoma artist collective"
- "Seattle LGBTQ+ entertainment"
- "Pacific Northwest drag shows"

---

## Priority 5: Performance & Core Web Vitals

### 5.1 Image Optimization
- Ensure images from Behold API are properly sized
- Add `loading="lazy"` to images
- Use WebP format (already from Behold)

### 5.2 Add Preload Hints
```html
<link rel="preload" href="style.css" as="style">
<link rel="dns-prefetch" href="https://feeds.behold.so">
```

---

## Implementation Checklist

### Quick Wins (< 1 hour)
- [ ] Add `robots.txt`
- [ ] Add `sitemap.xml`  
- [ ] Add canonical URL
- [ ] Add favicon
- [ ] Add hidden H1 tag
- [ ] Expand meta description
- [ ] Add Schema.org JSON-LD

### Medium Effort (1-3 hours)
- [ ] Add semantic HTML structure
- [ ] Create 1200x630 OG image
- [ ] Add `<noscript>` content fallback
- [ ] Add preload hints

### Ongoing
- [ ] Create Google Business Profile
- [ ] Monitor Google Search Console
- [ ] Add event pages as they happen
- [ ] Build backlinks from local event sites

---

## Measuring Success

### Tools to Set Up
1. **Google Search Console** - Track search rankings and crawl issues
2. **Google Analytics 4** - Track visitor behavior
3. **PageSpeed Insights** - Monitor performance

### Key Metrics to Track
- Search impressions for "Haus of Sutra"
- Click-through rate from search
- Local search visibility (Seattle/Tacoma)
- Social sharing engagement

---

## Next Steps

Would you like me to implement any of these changes? I recommend starting with:
1. Adding `robots.txt` and `sitemap.xml`
2. Adding semantic HTML with an H1 tag
3. Adding Schema.org structured data
4. Expanding the meta description
