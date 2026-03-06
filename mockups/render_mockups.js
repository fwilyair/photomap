const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

async function renderMockups() {
  const browser = await puppeteer.launch();
  const options = ['option_a', 'option_b', 'option_c'];
  const outDir = '/Users/seven/.gemini/antigravity/brain/05d8b464-e9fe-4753-91fc-2415c29970c7';
  
  for (const opt of options) {
    const page = await browser.newPage();
    // iPhone 15 Pro dimensions
    await page.setViewport({ width: 393, height: 852, deviceScaleFactor: 3 });
    const fileUrl = 'file://' + path.join(__dirname, `${opt}.html`);
    await page.goto(fileUrl, { waitUntil: 'networkidle0' });
    
    const outPath = path.join(outDir, `${opt}_mockup.png`);
    await page.screenshot({ path: outPath });
    console.log(`Saved ${outPath}`);
  }

  await browser.close();
}

renderMockups().catch(err => console.error(err));
