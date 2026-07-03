const jstNow = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Tokyo' }));
const year = jstNow.getFullYear();
const month = String(jstNow.getMonth() + 1).padStart(2, '0');
const day = String(jstNow.getDate()).padStart(2, '0');
const hours = String(jstNow.getHours()).padStart(2, '0');
const minutes = String(jstNow.getMinutes()).padStart(2, '0');
const nowStr = `${year}-${month}-${day} ${hours}:${minutes}`;
console.log(nowStr);
