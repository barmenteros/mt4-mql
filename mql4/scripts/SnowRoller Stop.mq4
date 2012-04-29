/**
 * SnowRoller Stop
 */
#include <stdlib.mqh>


#property show_inputs


/**
 * Initialisierung
 *
 * @return int - Fehlerstatus
 */
int init() {
   return(onInit(T_SCRIPT));
}


/**
 * Deinitialisierung
 *
 * @return int - Fehlerstatus
 */
int deinit() {
   return(catch("deinit()"));
}


/**
 * Main-Funktion
 *
 * @return int - Fehlerstatus
 */
int onStart() {
   return(catch("onStart()"));
}


