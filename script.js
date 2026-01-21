// Local Instagram Feed (synced via GitHub Actions)
const FEED_URL = './instagram/feed.json';

const wheel = document.getElementById('carousel');
const usernameEl = document.getElementById('username');
const profileAvatarEl = document.getElementById('profileAvatar');
const profileNameEl = document.getElementById('profileName');
const descriptionContentEl = document.getElementById('descriptionContent');
const descToggleBtn = document.getElementById('descToggle');
const postDescriptionPanel = document.getElementById('postDescription');

let items = [];
let numItems = 0;
let theta = 0;
let radius = 0;
let postCaptions = [];

// Fetch and render the feed
async function loadFeed() {
    try {
        const response = await fetch(FEED_URL);
        const data = await response.json();

        // Set username (if element exists)
        if (data.username && usernameEl) {
            usernameEl.textContent = '@' + data.username;
        }

        // Set profile picture (if element exists)
        if (data.profilePictureUrl && profileAvatarEl) {
            profileAvatarEl.src = data.profilePictureUrl;
            profileAvatarEl.style.display = 'block';
        }

        // Set profile info (if element exists)
        if (profileNameEl) {
            profileNameEl.textContent = "Seattle - Tacoma Artist Collective";
        }


        // Get first 6 posts
        const posts = data.posts.slice(0, 6);

        // Clear loading state
        wheel.innerHTML = '';

        // Create carousel items
        posts.forEach((post, index) => {
            const item = document.createElement('a');
            item.className = 'carousel-item';
            item.href = post.permalink;
            item.target = '_blank';
            item.dataset.index = index;
            item.dataset.caption = post.caption || 'No caption available';
            postCaptions[index] = post.caption || 'No caption available';

            // Use the large size image
            const imgUrl = post.sizes?.large?.mediaUrl || post.thumbnailUrl || post.mediaUrl;

            // Extract date from caption if calendar emoji exists
            let eventDate = '';
            // Match calendar emoji followed by text until newline
            const dateMatch = (post.caption || '').match(/[🗓📅📆]\s*([^\n\r]+)/);
            if (dateMatch && dateMatch[1]) {
                // Take only the part after the emoji, trim it
                eventDate = dateMatch[1].trim();
            }


            item.innerHTML = `
                <img src="${imgUrl}" alt="${post.prunedCaption || 'Instagram post'}">
                ${post.isReel || post.mediaType === 'VIDEO' ? '<span class="play-icon">▶</span>' : ''}
                ${eventDate ? `<div class="event-date">${eventDate}</div>` : ''}
            `;


            // Smart object-fit: use contain for tall images, cover for square/landscape
            const img = item.querySelector('img');
            const isVideo = post.isReel || post.mediaType === 'VIDEO';

            if (isVideo) {
                // Reels/videos fill the frame
                img.style.objectFit = 'cover';
            } else {
                // For images, detect aspect ratio on load
                img.onload = function () {
                    const ratio = this.naturalHeight / this.naturalWidth;
                    // If image is taller than 4:5 ratio (1.25), use contain to show full image
                    // Otherwise use cover to fill the card nicely
                    this.style.objectFit = ratio > 1.25 ? 'contain' : 'cover';
                };
            }

            wheel.appendChild(item);
        });

        // Update items reference and setup carousel
        items = document.querySelectorAll('.carousel-item');
        numItems = items.length;
        theta = 360 / numItems;

        setupCarousel();

    } catch (error) {
        console.error('Error loading Instagram feed:', error);
        wheel.innerHTML = '<div class="loading">Failed to load feed</div>';
    }
}

function setupCarousel() {
    const style = getComputedStyle(document.documentElement);
    const cardWidth = parseInt(style.getPropertyValue('--card-width')) || 300;

    // Calculate radius for the cylinder (smaller multiplier = cards closer together)
    radius = Math.round((cardWidth * 0.5) / Math.tan(Math.PI / numItems));

    // Position each item around the cylinder
    items.forEach((item, index) => {
        const angle = theta * index;
        item.style.transform = `rotateY(${angle}deg) translateZ(${radius}px)`;
    });

    rotateCarousel();
}

let targetAngle = 0;
let isDragging = false;
let startX = 0;
let startAngle = 0;
let velocity = 0;
let animationId = null;
let dragDistance = 0;

// Mouse events - only on carousel container
const carouselContainer = document.querySelector('.carousel-container');

carouselContainer.addEventListener('mousedown', (e) => {
    isDragging = true;
    startX = e.clientX;
    startAngle = targetAngle;
    velocity = 0;
    dragDistance = 0;
    cancelAnimationFrame(animationId);
    wheel.style.cursor = 'grabbing';
    e.preventDefault();
});

document.addEventListener('mousemove', (e) => {
    if (!isDragging) return;
    const dx = e.clientX - startX;
    dragDistance += Math.abs(e.movementX);
    const newAngle = startAngle + (dx * 0.2);
    velocity = newAngle - targetAngle;
    targetAngle = newAngle;
    rotateCarousel();
});

document.addEventListener('mouseup', () => {
    if (isDragging) {
        isDragging = false;
        wheel.style.cursor = 'grab';
        applyMomentum();
    }
});

// Touch events
carouselContainer.addEventListener('touchstart', (e) => {
    isDragging = true;
    startX = e.touches[0].clientX;
    startAngle = targetAngle;
    velocity = 0;
    dragDistance = 0;
    cancelAnimationFrame(animationId);
}, { passive: true });

document.addEventListener('touchmove', (e) => {
    if (!isDragging) return;
    const dx = e.touches[0].clientX - startX;
    dragDistance += Math.abs(dx - (startX - e.touches[0].clientX));
    const newAngle = startAngle + (dx * 0.5);
    velocity = newAngle - targetAngle;
    targetAngle = newAngle;
    rotateCarousel();
}, { passive: true });

document.addEventListener('touchend', () => {
    if (isDragging) {
        isDragging = false;
        applyMomentum();
    }
});

function rotateCarousel() {
    // TranslateZ pulls the wheel back so the front item is at Z=0
    wheel.style.transform = `translateZ(-${radius}px) rotateY(${targetAngle}deg)`;
    updateItemStyles();
}

function updateItemStyles() {
    let centeredIndex = 0;
    let maxVisibility = 0;

    items.forEach((item, i) => {
        const itemAngle = (theta * i + targetAngle) % 360;
        const normalizedAngle = ((itemAngle % 360) + 360) % 360;

        // Cosine-based visibility (front = 1, back = 0)
        let visibility = Math.cos((normalizedAngle * Math.PI) / 180);
        visibility = (visibility + 1) / 2;

        item.style.opacity = 0.3 + (visibility * 0.7);
        // Removed filter: brightness() as it causes significant stutter on mobile
        // item.style.filter = `brightness(${0.4 + visibility * 0.6})`;

        // Track which item is most visible (centered)
        if (visibility > maxVisibility) {
            maxVisibility = visibility;
            centeredIndex = i;
        }
    });

    // Update description panel with centered post caption
    if (postCaptions[centeredIndex]) {
        descriptionContentEl.textContent = postCaptions[centeredIndex];
    }
}

function applyMomentum() {
    if (Math.abs(velocity) > 0.1) {
        velocity *= 0.95;
        targetAngle += velocity;
        rotateCarousel();
        animationId = requestAnimationFrame(applyMomentum);
    } else {
        snapToNearest();
    }
}

function snapToNearest() {
    const snappedAngle = Math.round(targetAngle / theta) * theta;
    const diff = snappedAngle - targetAngle;

    if (Math.abs(diff) > 0.1) {
        targetAngle += diff * 0.6;
        rotateCarousel();
        animationId = requestAnimationFrame(snapToNearest);
    } else {
        targetAngle = snappedAngle;
        rotateCarousel();
    }
}

// Prevent click navigation while dragging
document.addEventListener('click', (e) => {
    const item = e.target.closest('.carousel-item');
    if (item && dragDistance > 10) {
        e.preventDefault();
        e.stopPropagation();
    }
}, true);

// Auto-rotation when idle (subtle and slow)
let idleTimer;
function startIdleRotation() {
    idleTimer = setInterval(() => {
        // Don't rotate if dragging or description is open
        if (!isDragging && !postDescriptionPanel.classList.contains('show')) {
            targetAngle -= 0.02;
            rotateCarousel();
        }
    }, 50);
}

function resetIdleTimer() {
    clearInterval(idleTimer);
    setTimeout(startIdleRotation, 8000);
}

document.addEventListener('mousedown', resetIdleTimer);
document.addEventListener('touchstart', resetIdleTimer);

// Toggle description panel on mobile
descToggleBtn.addEventListener('click', (e) => {
    e.stopPropagation(); // Prevent closing immediately
    postDescriptionPanel.classList.toggle('show');
    descToggleBtn.classList.toggle('active');

    // Update button text
    if (postDescriptionPanel.classList.contains('show')) {
        descToggleBtn.textContent = 'Close';
    } else {
        descToggleBtn.textContent = 'Description';
    }
});

// Close panel when clicking outside
document.addEventListener('click', (e) => {
    if (postDescriptionPanel.classList.contains('show') &&
        !postDescriptionPanel.contains(e.target) &&
        e.target !== descToggleBtn) {

        postDescriptionPanel.classList.remove('show');
        descToggleBtn.classList.remove('active');
        descToggleBtn.textContent = 'Description';
    }
});

// Initialize
window.addEventListener('resize', () => {
    if (numItems > 0) setupCarousel();
});

loadFeed().then(() => {
    resetIdleTimer();
});

// ============================================
// HAMBURGER MENU & MODALS
// ============================================

const hamburgerBtn = document.getElementById('hamburgerBtn');
const mobileMenu = document.getElementById('mobileMenu');
const aboutModal = document.getElementById('aboutModal');
const subscribeModal = document.getElementById('subscribeModal');
const aboutMenuBtn = document.getElementById('aboutMenuBtn');
const subscribeMenuBtn = document.getElementById('subscribeMenuBtn');

// Toggle mobile menu
hamburgerBtn.addEventListener('click', () => {
    hamburgerBtn.classList.toggle('active');
    mobileMenu.classList.toggle('show');
});

// Close mobile menu when clicking outside
document.addEventListener('click', (e) => {
    if (!hamburgerBtn.contains(e.target) && !mobileMenu.contains(e.target)) {
        hamburgerBtn.classList.remove('active');
        mobileMenu.classList.remove('show');
    }
});

// Open About modal
aboutMenuBtn.addEventListener('click', () => {
    aboutModal.classList.add('show');
    mobileMenu.classList.remove('show');
    hamburgerBtn.classList.remove('active');
});

// Open Subscribe modal
subscribeMenuBtn.addEventListener('click', () => {
    subscribeModal.classList.add('show');
    mobileMenu.classList.remove('show');
    hamburgerBtn.classList.remove('active');
});

// Close modals
document.querySelectorAll('[data-close]').forEach(btn => {
    btn.addEventListener('click', () => {
        const modalId = btn.dataset.close;
        document.getElementById(modalId).classList.remove('show');
    });
});

// Close modal on Escape key
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        aboutModal.classList.remove('show');
        subscribeModal.classList.remove('show');
        mobileMenu.classList.remove('show');
        hamburgerBtn.classList.remove('active');
    }
});

// Subscribe form handler (placeholder for now)
const subscribeForm = document.getElementById('subscribeForm');
subscribeForm.addEventListener('submit', (e) => {
    e.preventDefault();
    const email = subscribeForm.querySelector('input').value;
    console.log('Email submitted:', email);
    alert('Thanks for subscribing! We\'ll be in touch soon.');
    subscribeForm.reset();
    subscribeModal.classList.remove('show');
});
