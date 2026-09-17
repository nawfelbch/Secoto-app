import { renderToString } from "react-dom/server";
import OnDemandBooking from "../../src/ondemand/OnDemandBooking";
import MyOrdersPanel from "../../src/ondemand/MyOrdersPanel";
import SubscriptionPanel from "../../src/ondemand/SubscriptionPanel";
import AdminOnDemand from "../../src/ondemand/AdminOnDemand";
import LiveTrackingView from "../../src/ondemand/LiveTrackingView";
import LiveTrackingMap from "../../src/ondemand/LiveTrackingMap";
import LiveSharingControl from "../../src/ondemand/LiveSharingControl";
import { DispatchPreferencesPanel, OffersPanel, OfferDetail } from "../../src/ondemand/PartnerOffers";

const flags = { auto_pricing: true, od_payments: true, subscriptions: true, dispatch_notifications: true, live_tracking: true };
const cases = [
  ["OnDemandBooking", <OnDemandBooking flags={flags} />],
  ["MyOrdersPanel", <MyOrdersPanel flags={flags} />],
  ["SubscriptionPanel (flags off)", <SubscriptionPanel flags={{}} />],
  ["SubscriptionPanel", <SubscriptionPanel flags={flags} />],
  ["AdminOnDemand", <AdminOnDemand flags={flags} transporters={[]} />],
  ["LiveTrackingView", <LiveTrackingView missionId="m-1" />],
  ["LiveTrackingMap", <LiveTrackingMap carrier={{ lat: 48.8, lng: 2.3, accuracy_m: 25 }} destination={{ lat: 45.7, lng: 4.8 }} />],
  ["LiveTrackingMap (sans position)", <LiveTrackingMap carrier={null} destination={null} />],
  ["LiveSharingControl", <LiveSharingControl mission={{ id: "m-1", status: "assigned", progressStatus: "pickup_completed" }} />],
  ["DispatchPreferencesPanel", <DispatchPreferencesPanel transporterType="convoyeur" />],
  ["OffersPanel", <OffersPanel />],
  ["OfferDetail", <OfferDetail offerId="o-1" />],
];
let failures = 0;
for (const [name, element] of cases) {
  try {
    const html = renderToString(element);
    console.log(`ok   ${name} (${html.length} caractères)`);
  } catch (error) {
    failures += 1;
    console.log(`ECHEC ${name} : ${error?.message}`);
  }
}
console.log(failures ? `ECHECS: ${failures}` : "Tous les écrans se rendent sans erreur.");
